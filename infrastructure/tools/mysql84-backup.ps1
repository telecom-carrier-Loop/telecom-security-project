[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [ValidateSet('Backup', 'RestoreTest', 'Status')][string]$Action = 'Status'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { $RepositoryPath = Join-Path $PSScriptRoot '../..' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$root = Join-Path $repo '.secrets/backups/mysql84/pc2'
$latest = Join-Path $root 'latest.json'
$utf8 = [Text.UTF8Encoding]::new($false)
$pc2Uuid = 'f1868a2a-a5a5-11f1-8815-9693e922f083'
$testArguments = @('--server-id=9032', '--event-scheduler=OFF', '--skip-replica-start=ON', '--innodb-buffer-pool-size=128M')

function Invoke-BackupDocker([string[]]$Arguments, [switch]$AllowFailure) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Arguments -contains '-it') { & docker @Arguments; $code = $LASTEXITCODE; $lines = @() }
        else { $lines = @(& docker @Arguments 2>&1); $code = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $previous }
    if ($code -ne 0) {
        if ($AllowFailure) { return }
        throw ('Docker ' + $Arguments[0] + ' failed. Keep backup files; run Status. Do not restore into mysql-lab.')
    }
    foreach ($line in $lines) { $line.ToString() }
}
function Write-BackupText([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8) }
function Save-BackupState([string]$Stage) {
    $state.Stage = $Stage
    Write-BackupText $latest ($state | ConvertTo-Json -Depth 8)
    Write-BackupText (Join-Path $state.Directory 'state.json') ($state | ConvertTo-Json -Depth 8)
}
function Get-BackupContainer([string]$Id) {
    $items = (@(Invoke-BackupDocker @('inspect', $Id)) -join "`n") | ConvertFrom-Json
    if (@($items).Count -ne 1) { throw 'Expected one container.' }
    $items[0]
}
function Get-BackupSource {
    $role = Get-Content -LiteralPath (Join-Path $repo '.secrets/mysql84-replication/pc2/state.json') -Raw | ConvertFrom-Json
    if ($role.Stage -ne 'replica-ready') { throw 'PC2 replication must pass Verify first.' }
    $source = Get-BackupContainer $role.ProductionId
    $mounts = @($source.Mounts)
    if ($source.Name -ne '/mysql-lab' -or -not $source.State.Running -or $source.Image -ne $role.ImageId -or $mounts.Count -ne 1 -or $mounts[0].Type -ne 'volume' -or $mounts[0].Name -ne $role.CloneVolume -or $mounts[0].Destination -ne '/var/lib/mysql' -or -not $mounts[0].RW) { throw 'Actual PC2 source identity changed.' }
    $writers = @(Invoke-BackupDocker @('ps', '--no-trunc', '--filter', ('volume=' + $role.CloneVolume), '--format', '{{.ID}}'))
    if ($writers.Count -ne 1 -or $writers[0] -ne $source.Id) { throw 'Unexpected shared use of the live replica volume.' }
    [PSCustomObject]@{ Role = $role; Container = $source }
}
function Assert-TestContainer($Container) {
    $mounts = @($Container.Mounts)
    $data = @($mounts | Where-Object Destination -eq '/var/lib/mysql')
    $secret = @($mounts | Where-Object Destination -eq '/run/loop-restore')
    $ports = $Container.HostConfig.PortBindings
    $portCount = 0
    if ($null -ne $ports) { $portCount = @($ports.PSObject.Properties).Count }
    if ($Container.Id -eq $state.SourceId -or $Container.Name -ne ('/' + $state.TestName) -or $Container.Image -ne $state.ImageId -or $Container.HostConfig.NetworkMode -ne 'none' -or $Container.HostConfig.RestartPolicy.Name -ne 'no' -or $portCount -ne 0 -or $mounts.Count -ne 2 -or $data.Count -ne 1 -or $data[0].Type -ne 'volume' -or $data[0].Name -ne $state.TestVolume -or -not $data[0].RW -or $secret.Count -ne 1 -or $secret[0].Type -ne 'bind' -or $secret[0].RW -or (@($Container.Config.Cmd) -join "`n") -cne ($testArguments -join "`n")) { throw 'Unsafe restore-test container. No SQL or stop operation is allowed.' }
    if ($state.TestVolume -in @($sourceInfo.Role.SourceVolume, $sourceInfo.Role.CloneVolume)) { throw 'Restore test cannot use an original or live data volume.' }
    $writers = @(Invoke-BackupDocker @('ps', '--no-trunc', '--filter', ('volume=' + $state.TestVolume), '--format', '{{.ID}}'))
    if ($Container.State.Running -and ($writers.Count -ne 1 -or $writers[0] -ne $Container.Id)) { throw 'Unexpected shared use of the restore-test volume.' }
    if (-not $Container.State.Running -and $writers.Count -ne 0) { throw 'Another container is using the restore-test volume.' }
}
function Read-BackupManifest {
    if ((Split-Path -Path $state.Directory -Parent) -ne $root -or (Split-Path -Path $state.Directory -Leaf) -notmatch '^\d{8}-\d{6}-\d{3}-[a-f0-9]{6}$') { throw 'Backup directory is outside this tool workspace.' }
    $manifestFile = Join-Path $state.Directory 'manifest.json'
    if ((Get-FileHash -LiteralPath $manifestFile).Hash -ine $state.ManifestSha256) { throw 'Backup manifest hash changed.' }
    $manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json
    $tables = @($manifest.Tables)
    if ($manifest.Format -ne 'loop-mysql84-backup-v1' -or $manifest.Database -ne 'my_new_board_db' -or $manifest.SourceUuid -ne $pc2Uuid -or $manifest.ImageId -ne $state.ImageId -or $tables.Count -eq 0 -or @($tables | Select-Object -Unique).Count -ne $tables.Count) { throw 'Unexpected backup manifest.' }
    foreach ($table in $tables) { if ($table -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$') { throw 'Unsupported table identifier.' } }
    $dump = Join-Path $state.Directory 'snapshot.sql'
    $item = Get-Item -LiteralPath $dump
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -ne $manifest.Length -or (Get-FileHash -LiteralPath $dump).Hash -ine $manifest.Sha256) { throw 'Backup SQL integrity check failed.' }
    $manifest
}

if ($Action -eq 'Status') {
    if (-not (Test-Path -LiteralPath $latest)) { Write-Host 'No backup run exists.'; exit 0 }
    $state = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
    Write-Host ('Stage: ' + $state.Stage)
    Write-Host ('Backup directory: ' + $state.Directory)
    if ($state.TestId) { Invoke-BackupDocker @('inspect', '--format', 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}}', $state.TestId) }
    exit 0
}
$sourceInfo = Get-BackupSource

if ($Action -eq 'Backup') {
    if (Test-Path -LiteralPath $latest) {
        $previous = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
        if ($previous.Stage -in @('test-created', 'test-running', 'restoring', 'restore-checked')) { throw 'Finish or inspect the pending restore test before starting another backup.' }
    }
    $tag = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $directory = Join-Path $root $tag
    $null = New-Item -ItemType Directory -Path $directory -Force
    $state = [PSCustomObject]@{
        Stage='backup-started'; Directory=$directory; SourceId=$sourceInfo.Container.Id
        ImageId=$sourceInfo.Container.Image; TempDirectory=('/tmp/loop-backup-' + $tag)
        TestName=('loop-mysql84-restore-' + $tag); TestVolume=('loop-mysql84-restore-data-' + $tag)
        TestId=''; ManifestSha256=''
    }
    Save-BackupState 'backup-started'
    $primaryUuid = $sourceInfo.Role.PrimaryUuid
    $preflight = @"
SET @loop_guard = IF(VERSION()='8.4.11' AND @@GLOBAL.server_id=2
    AND @@GLOBAL.server_uuid='$pc2Uuid' AND @@GLOBAL.read_only=1 AND @@GLOBAL.super_read_only=1
    AND @@GLOBAL.gtid_mode='ON' AND @@GLOBAL.enforce_gtid_consistency='ON'
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME='' AND SOURCE_UUID='$primaryUuid' AND SERVICE_STATE='ON' AND LAST_ERROR_NUMBER=0)=1
    AND (SELECT COUNT(1) FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME='' AND SERVICE_STATE='ON')=1
    AND (SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_worker)=0
    AND (SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_coordinator)=0
    AND (SELECT COUNT(1) FROM information_schema.TABLES WHERE TABLE_SCHEMA='my_new_board_db' AND TABLE_TYPE='BASE TABLE')>0
    AND (SELECT COUNT(1) FROM information_schema.TABLES WHERE TABLE_SCHEMA='my_new_board_db' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB')=0,
    'SELECT 1','SELECT BACKUP_REPLICA_NOT_HEALTHY');
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
SELECT CONCAT('loop_table=',HEX(TABLE_NAME)) FROM information_schema.TABLES
WHERE TABLE_SCHEMA='my_new_board_db' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;
"@
    $runner = Join-Path $directory 'root-file.sh'
    Write-BackupText $runner "#!/bin/sh`nset -eu`nmysql --user=root --password --batch --skip-column-names < `"`$1`" > `"`$2`"`n"
    $sqlFile = Join-Path $directory 'preflight.sql'
    Write-BackupText $sqlFile $preflight
    $null = Invoke-BackupDocker @('exec', $state.SourceId, 'mkdir', '-p', '-m', '700', $state.TempDirectory)
    $null = Invoke-BackupDocker @('cp', $runner, ($state.SourceId + ':' + $state.TempDirectory + '/root-file.sh'))
    $null = Invoke-BackupDocker @('cp', $sqlFile, ($state.SourceId + ':' + $state.TempDirectory + '/preflight.sql'))
    Write-Host 'Enter CURRENT PC2 root password for backup preflight (first prompt).'
    Invoke-BackupDocker @('exec', '-it', $state.SourceId, 'sh', ($state.TempDirectory + '/root-file.sh'), ($state.TempDirectory + '/preflight.sql'), ($state.TempDirectory + '/preflight.txt'))
    $metadata = Join-Path $directory 'preflight.txt'
    $null = Invoke-BackupDocker @('cp', ($state.SourceId + ':' + $state.TempDirectory + '/preflight.txt'), $metadata)
    $tables = @(foreach ($line in [IO.File]::ReadAllLines($metadata)) {
        if ($line -cmatch '^loop_table=([A-F0-9]+)$') {
            $hex = $Matches[1]
            if ($hex.Length % 2 -ne 0) { throw 'Invalid table metadata.' }
            $bytes = New-Object byte[] ($hex.Length / 2)
            for ($i=0; $i -lt $bytes.Length; $i++) { $bytes[$i]=[Convert]::ToByte($hex.Substring($i*2,2),16) }
            $table = $utf8.GetString($bytes)
            if ($table -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$') { throw 'Unsupported table identifier.' }
            $table
        }
    })
    if ($tables.Count -eq 0 -or @($tables | Select-Object -Unique).Count -ne $tables.Count) { throw 'Preflight did not return unique base tables.' }
    Write-Host 'Enter SAME PC2 root password for mysqldump (second prompt). Do not run schema migrations during this dump.'
    Invoke-BackupDocker @('exec', '-it', $state.SourceId, 'mysqldump', '--user=root', '--password', '--default-character-set=utf8mb4', '--single-transaction', '--quick', '--skip-lock-tables', '--no-tablespaces', '--routines', '--events', '--triggers', '--hex-blob', '--set-gtid-purged=OFF', ('--result-file=' + $state.TempDirectory + '/snapshot.sql'), '--databases', 'my_new_board_db')
    $partial = Join-Path $directory 'snapshot.sql.partial'
    $null = Invoke-BackupDocker @('cp', ($state.SourceId + ':' + $state.TempDirectory + '/snapshot.sql'), $partial)
    $headers = @(Select-String -LiteralPath $partial -Pattern '^-- Table structure for table `([A-Za-z0-9_]+)`$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($headers.Count -ne $tables.Count -or @(Compare-Object $headers $tables).Count -ne 0 -or @(Select-String -LiteralPath $partial -Pattern '^SET @@GLOBAL.GTID_PURGED=').Count -ne 0 -or @(Get-Content -LiteralPath $partial -Tail 5 | Select-String -Pattern '^-- Dump completed on ').Count -ne 1) { throw 'Backup is incomplete or table metadata changed. Keep partial files; no valid backup was published.' }
    $dump = Join-Path $directory 'snapshot.sql'
    [IO.File]::Move($partial, $dump)
    $manifest = [PSCustomObject]@{Format='loop-mysql84-backup-v1'; Database='my_new_board_db'; SourceUuid=$pc2Uuid; ImageId=$state.ImageId; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Tables=$tables; Length=(Get-Item $dump).Length; Sha256=(Get-FileHash $dump).Hash}
    $manifestFile = Join-Path $directory 'manifest.json'
    Write-BackupText $manifestFile ($manifest | ConvertTo-Json -Depth 6)
    $state.ManifestSha256 = (Get-FileHash $manifestFile).Hash
    Save-BackupState 'backup-ready'
    Write-Host ('PASS: backup saved; ' + $tables.Count + ' base tables, SHA256 and completion marker checked.')
    Write-Host ('Backup directory: ' + $directory)
    Write-Host 'This is a data-recovery dump (GTID_PURGED omitted), not a replica reseed or a scheduled backup.'
    exit 0
}

$state = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
if ($state.Stage -notin @('backup-ready', 'test-created', 'test-running', 'restoring', 'restore-checked', 'restore-failed', 'restore-verified')) { throw 'A complete backup is required.' }
if ($state.SourceId -ne $sourceInfo.Container.Id -or $state.ImageId -ne $sourceInfo.Container.Image) { throw 'Backup source identity changed.' }
$manifest = Read-BackupManifest
if ($state.Stage -eq 'restore-verified') { Write-Host 'This backup already passed its restore test. Run Status for the recorded result.'; exit 0 }
$secrets = Join-Path $state.Directory 'restore-private'
if (-not $state.TestId) {
    $null = New-Item -ItemType Directory -Path $secrets
    $random = New-Object byte[] 14
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($random) } finally { $generator.Dispose() }
    $password = 'Lt9!' + [BitConverter]::ToString($random).Replace('-','').ToLowerInvariant()
    Write-BackupText (Join-Path $secrets 'root-password') $password
    Write-BackupText (Join-Path $secrets 'client.cnf') "[client]`nuser=root`npassword=$password`n"
    $null = Invoke-BackupDocker @('volume', 'create', $state.TestVolume)
    $created = @(Invoke-BackupDocker (@('create', '--name', $state.TestName, '--network', 'none', '--restart=no', '--memory', '1g', '--mount', ('type=volume,source=' + $state.TestVolume + ',target=/var/lib/mysql'), '--mount', ('type=bind,source=' + $secrets + ',target=/run/loop-restore,readonly'), '--env', 'MYSQL_ROOT_PASSWORD_FILE=/run/loop-restore/root-password', '--env', 'MYSQL_ROOT_HOST=%', $state.ImageId) + $testArguments))
    $state.TestId = ($created -join '').Trim()
    Save-BackupState 'test-created'
}
$test = Get-BackupContainer $state.TestId
Assert-TestContainer $test
$safeToStop = $true
try {
    if (-not $test.State.Running) { $null = Invoke-BackupDocker @('start', $state.TestId) }
    Save-BackupState 'test-running'
    $ready = $false
    for ($attempt=0; $attempt -lt 24; $attempt++) {
        $test = Get-BackupContainer $state.TestId
        Assert-TestContainer $test
        if (-not $test.State.Running) { throw 'Restore-test container stopped during initialization. Run Status.' }
        $rows = @(Invoke-BackupDocker -Arguments @('exec', $state.TestId, 'sh', '-c', 'test "$(cat /proc/1/comm)" = mysqld && mysql --defaults-extra-file=/run/loop-restore/client.cnf --batch --skip-column-names --execute="SELECT VERSION(),@@GLOBAL.server_id;"') -AllowFailure)
        if (@($rows | Where-Object { $_ -ceq "8.4.11`t9032" }).Count -eq 1) { $ready=$true; break }
        if ($attempt % 4 -eq 0) { Write-Host 'Waiting for the isolated MySQL restore-test server...' }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { throw 'Isolated MySQL did not become ready within 120 seconds. Run Status.' }
    $identityGuard = @"
SET @loop_guard=IF(VERSION()='8.4.11' AND @@GLOBAL.server_id=9032
    AND @@GLOBAL.server_uuid<>'$pc2Uuid' AND @@GLOBAL.server_uuid<>'$($sourceInfo.Role.PrimaryUuid)'
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration)=0,
    'SELECT 1','SELECT RESTORE_TEST_IDENTITY_CHANGED');
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
"@
    $guardFile = Join-Path $state.Directory 'restore-guard.sql'
    Write-BackupText $guardFile ($identityGuard + "`nDROP DATABASE IF EXISTS my_new_board_db;")
    $runner = Join-Path $state.Directory 'restore-file.sh'
    Write-BackupText $runner "#!/bin/sh`nset -eu`nmysql --defaults-extra-file=/run/loop-restore/client.cnf --batch --skip-column-names < `"`$1`"`n"
    $null = Invoke-BackupDocker @('cp', $runner, ($state.TestId + ':/tmp/loop-restore-file.sh'))
    $null = Invoke-BackupDocker @('cp', $guardFile, ($state.TestId + ':/tmp/loop-restore-guard.sql'))
    $null = Invoke-BackupDocker @('cp', (Join-Path $state.Directory 'snapshot.sql'), ($state.TestId + ':/tmp/loop-restore-snapshot.sql'))
    Save-BackupState 'restoring'
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'sh', '/tmp/loop-restore-file.sh', '/tmp/loop-restore-guard.sql')
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'sh', '/tmp/loop-restore-file.sh', '/tmp/loop-restore-snapshot.sql')
    $qualified = @($manifest.Tables | ForEach-Object { '`my_new_board_db`.`' + $_ + '`' })
    $check = $identityGuard + "`nCHECK TABLE " + ($qualified -join ',') + ";`n"
    foreach ($table in $manifest.Tables) { $check += "SELECT CONCAT('loop_rows=$table',CHAR(9),COUNT(1)) FROM ``my_new_board_db``.``$table``;`n" }
    $checkFile = Join-Path $state.Directory 'restore-check.sql'
    Write-BackupText $checkFile $check
    $null = Invoke-BackupDocker @('cp', $checkFile, ($state.TestId + ':/tmp/loop-restore-check.sql'))
    $report = @(Invoke-BackupDocker @('exec', $state.TestId, 'sh', '/tmp/loop-restore-file.sh', '/tmp/loop-restore-check.sql'))
    foreach ($table in $manifest.Tables) {
        $expected = 'my_new_board_db.' + $table + "`tcheck`tstatus`tOK"
        if (@($report | Where-Object { $_ -ceq $expected }).Count -ne 1 -or @($report | Where-Object { $_ -cmatch ('^loop_rows=' + [regex]::Escape($table) + '\t[0-9]+$') }).Count -ne 1) { throw 'Restored table check or row count failed.' }
    }
    Write-BackupText (Join-Path $state.Directory 'restore-report.txt') ($report -join "`n")
    Save-BackupState 'restore-checked'
}
catch { Save-BackupState 'restore-failed'; throw }
finally {
    if ($safeToStop) {
        $test = Get-BackupContainer $state.TestId
        Assert-TestContainer $test
        if ($test.State.Running) { $null = Invoke-BackupDocker @('stop', '--time', '60', $state.TestId) }
        $test = Get-BackupContainer $state.TestId
        if ($test.State.Running -or $test.State.ExitCode -ne 0) { Save-BackupState 'restore-failed'; throw 'Restore-test shutdown was not clean. Original replica is unchanged; run Status.' }
    }
}
Save-BackupState 'restore-verified'
Write-Host ('PASS: isolated restore verified; ' + @($manifest.Tables).Count + ' tables CHECK TABLE OK; row counts saved.')
foreach ($line in $report) { if ($line -clike 'loop_rows=*') { Write-Host $line } }
Write-Host 'Only the isolated test container was stopped. Live replica, replication and original volumes were retained.'
