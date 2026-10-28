[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [ValidateSet('SaveCredential', 'PreflightSaved', 'BackupSaved', 'Backup', 'RestoreTest', 'Status')][string]$Action = 'Status',
    [ValidateSet('Replica', 'Primary')][string]$SourceRole = 'Replica'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { $RepositoryPath = Join-Path $PSScriptRoot '../..' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$replicaRoot = Join-Path $repo '.secrets/backups/mysql84/pc2'
$root = if ($SourceRole -eq 'Primary') { Join-Path $repo '.secrets/backups/mysql84/pc2-primary' } else { $replicaRoot }
$latest = Join-Path $root 'latest.json'
# Both roles use the same container-local loop_backup account and Windows DPAPI identity.
$credentialDirectory = Join-Path $replicaRoot 'credentials'
$credentialFile = Join-Path $credentialDirectory 'loop_backup.clixml'
$utf8 = [Text.UTF8Encoding]::new($false)
$pc2Uuid = 'f1868a2a-a5a5-11f1-8815-9693e922f083'
$testArguments = @('--server-id=9032', '--event-scheduler=OFF', '--skip-replica-start=ON', '--innodb-buffer-pool-size=128M')
$script:BackupDockerExitCode = 0

function Invoke-BackupDocker([string[]]$Arguments, [switch]$AllowFailure) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Arguments -contains '-it') { & docker @Arguments; $code = $LASTEXITCODE; $lines = @() }
        else { $lines = @(& docker @Arguments 2>&1); $code = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $previous }
    $script:BackupDockerExitCode = $code
    if ($code -ne 0) {
        if ($AllowFailure) { return }
        # Report only the known guard marker; never echo arbitrary client/authentication output.
        if (($lines -join "`n") -match "1054[^\r\n]*Unknown column 'BACKUP_PRIMARY_NOT_READY'") {
            throw 'BACKUP_PRIMARY_NOT_READY: PC2 is not a writable Primary with stopped replication. No dump was started.'
        }
        throw ('Docker ' + $Arguments[0] + ' failed. Keep backup files; run Status. Do not restore into mysql-lab.')
    }
    foreach ($line in $lines) { $line.ToString() }
}
function Write-BackupText([string]$Path, [string]$Text) { [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8) }
function New-PrivateBackupDirectory([string]$Path) {
    if ($env:OS -ne 'Windows_NT') { throw 'Saved backup credentials require Windows DPAPI.' }
    $null = New-Item -ItemType Directory -Path $Path -Force
    if (((Get-Item -LiteralPath $Path).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Credential directory cannot be a reparse point.' }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = Get-Acl -LiteralPath $Path
    $acl.SetOwner($sid)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($identity in @($sid, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $Path -AclObject $acl
}
function Read-SavedBackupCredential {
    if ($env:OS -ne 'Windows_NT') { throw 'Saved backup credentials require Windows DPAPI.' }
    try {
        $item = Get-Item -LiteralPath $credentialFile
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Invalid credential file.' }
        $credential = Import-Clixml -LiteralPath $credentialFile
        if ($credential -isnot [Management.Automation.PSCredential] -or $credential.UserName -cne 'loop_backup' -or $credential.Password.Length -eq 0) { throw 'Invalid credential account.' }
        $credential
    }
    catch { throw 'Cannot load loop_backup credential. Run SaveCredential once on PC2 as this Windows user; never store root credentials.' }
}
function Initialize-BackupClient($Credential) {
    $runtime = Join-Path $credentialDirectory ('runtime-' + [guid]::NewGuid().ToString('N'))
    $hostConfig = Join-Path $runtime 'client.cnf'
    $client = $state.TempDirectory + '/client.cnf'
    New-PrivateBackupDirectory $runtime
    try {
        # Quote option-file values, including MySQL-generated punctuation and escape characters.
        $plain = $Credential.GetNetworkCredential().Password
        $escaped = $plain.Replace('\', '\\').Replace('"', '\"').Replace("`r", '\r').Replace("`n", '\n').Replace("`t", '\t').Replace("`b", '\b')
        $config = "[client]`nuser=loop_backup`nprotocol=SOCKET`npassword=`"$escaped`"`n"
        Write-BackupText $hostConfig $config
        $null = Invoke-BackupDocker @('cp', $hostConfig, ($state.SourceId + ':' + $client))
        $null = Invoke-BackupDocker @('exec', $state.SourceId, 'chmod', '600', $client)
        $mode = @(Invoke-BackupDocker @('exec', $state.SourceId, 'stat', '-c', '%a', $client))
        if ($mode.Count -ne 1 -or $mode[0] -cne '600') { throw 'Container-local backup client config must have mode 600.' }
    }
    finally {
        $plain = $null; $escaped = $null; $config = $null
        if (Test-Path -LiteralPath $hostConfig) { Remove-Item -LiteralPath $hostConfig -Force }
        Remove-Item -LiteralPath $runtime -Force
    }
    $client
}
function Save-BackupState([string]$Stage) {
    $state.Stage = $Stage
    # A role probe must not replace the latest complete backup/restore pointer.
    if ($Action -ne 'PreflightSaved') { Write-BackupText $latest ($state | ConvertTo-Json -Depth 8) }
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
    $manifestRole = if ($null -ne $manifest.PSObject.Properties['SourceRole']) { $manifest.SourceRole } else { 'Replica' }
    if ($manifestRole -cne $SourceRole) { throw 'Backup source role does not match this restore workspace.' }
    $tables = @($manifest.Tables)
    if ($manifest.Format -ne 'loop-mysql84-backup-v1' -or $manifest.Database -ne 'my_new_board_db' -or $manifest.SourceUuid -ne $pc2Uuid -or $manifest.ImageId -ne $state.ImageId -or $tables.Count -eq 0 -or @($tables | Select-Object -Unique).Count -ne $tables.Count) { throw 'Unexpected backup manifest.' }
    foreach ($table in $tables) { if ($table -notmatch '^[A-Za-z_][A-Za-z0-9_]{0,63}$') { throw 'Unsupported table identifier.' } }
    $dump = Join-Path $state.Directory 'snapshot.sql'
    $item = Get-Item -LiteralPath $dump
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -ne $manifest.Length -or (Get-FileHash -LiteralPath $dump).Hash -ine $manifest.Sha256) { throw 'Backup SQL integrity check failed.' }
    $manifest
}

if ($Action -eq 'Status') {
    Write-Host ('Source role: ' + $SourceRole)
    if (-not (Test-Path -LiteralPath $latest)) { Write-Host 'No backup run exists.'; exit 0 }
    $state = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
    Write-Host ('Stage: ' + $state.Stage)
    Write-Host ('Backup directory: ' + $state.Directory)
    if ($null -ne $state.PSObject.Properties['ReadyProbeExitCode']) { Write-Host ('Last readiness exit code: ' + $state.ReadyProbeExitCode) }
    if ($state.TestId) { Invoke-BackupDocker @('inspect', '--format', 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} error={{json .State.Error}}', $state.TestId) }
    exit 0
}
$null = New-Item -ItemType Directory -Path $root -Force
$null = New-Item -ItemType Directory -Path $replicaRoot -Force
# Serialize both roles with the already installed Replica scheduler.
try { $operationLock = [IO.File]::Open((Join-Path $replicaRoot 'operation.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { throw 'Another backup, credential setup or restore test is running. No action was started.' }
try {
$sourceInfo = Get-BackupSource

if ($Action -eq 'SaveCredential') {
    if (Test-Path -LiteralPath $credentialFile) { throw 'A credential already exists. Use BackupSaved to verify it; this action will not replace it.' }
    New-PrivateBackupDirectory $credentialDirectory
    $secure = Read-Host 'Enter the loop_backup password generated on PC1 (not the root password)' -AsSecureString
    try {
        if ($secure.Length -eq 0) { throw 'Backup password cannot be empty.' }
        $credential = [Management.Automation.PSCredential]::new('loop_backup', $secure)
        $credential | Export-Clixml -LiteralPath $credentialFile -NoClobber
        $null = Read-SavedBackupCredential
    }
    finally { $credential = $null; if ($null -ne $secure) { $secure.Dispose() } }
    Write-Host 'PASS: loop_backup credential encrypted for this Windows user on this PC. Next run BackupSaved to verify authentication and create a backup.'
    exit 0
}

if ($Action -in @('Backup', 'BackupSaved', 'PreflightSaved')) {
    $saved = $Action -in @('BackupSaved', 'PreflightSaved')
    $savedCredential = $null
    if ($saved) { $savedCredential = Read-SavedBackupCredential }
    if (Test-Path -LiteralPath $latest) {
        $previous = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
        if ($previous.Stage -in @('test-created', 'test-running', 'restoring', 'restore-checked')) { throw 'Finish or inspect the pending restore test before starting another backup.' }
    }
    $tag = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0,6)
    $testPrefix = if ($SourceRole -eq 'Primary') { 'loop-mysql84-primary' } else { 'loop-mysql84' }
    $directory = Join-Path $root $(if ($Action -eq 'PreflightSaved') { 'preflight-' + $tag } else { $tag })
    $null = New-Item -ItemType Directory -Path $directory -Force
    $state = [PSCustomObject]@{
        Stage='backup-started'; SourceRole=$SourceRole; Directory=$directory; SourceId=$sourceInfo.Container.Id
        ImageId=$sourceInfo.Container.Image; TempDirectory=('/tmp/loop-backup-' + $tag)
        TestName=($testPrefix + '-restore-' + $tag); TestVolume=($testPrefix + '-restore-data-' + $tag)
        TestId=''; ManifestSha256=''
    }
    Save-BackupState 'backup-started'
    try {
    $primaryUuid = $sourceInfo.Role.PrimaryUuid
    $roleGuard = if ($SourceRole -eq 'Primary') {
@"
    AND @@GLOBAL.read_only=0 AND @@GLOBAL.super_read_only=0
    AND @@GLOBAL.log_bin=1 AND @@GLOBAL.log_replica_updates=1
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_status WHERE SERVICE_STATE='ON')=0
    AND (SELECT COUNT(1) FROM performance_schema.replication_applier_status WHERE SERVICE_STATE='ON')=0
"@
    } else {
@"
    AND @@GLOBAL.read_only=1 AND @@GLOBAL.super_read_only=1
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME='' AND SOURCE_UUID='$primaryUuid' AND SERVICE_STATE='ON' AND LAST_ERROR_NUMBER=0)=1
    AND (SELECT COUNT(1) FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME='' AND SERVICE_STATE='ON')=1
"@
    }
    $guardFailure = if ($SourceRole -eq 'Primary') { 'BACKUP_PRIMARY_NOT_READY' } else { 'BACKUP_REPLICA_NOT_HEALTHY' }
    $preflight = @"
SET @loop_guard = IF(VERSION()='8.4.11' AND @@GLOBAL.server_id=2
    AND @@GLOBAL.server_uuid='$pc2Uuid'
    AND @@GLOBAL.gtid_mode='ON' AND @@GLOBAL.enforce_gtid_consistency='ON'
$roleGuard
    AND (SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_worker)=0
    AND (SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_coordinator)=0
    AND (SELECT COUNT(1) FROM information_schema.TABLES WHERE TABLE_SCHEMA='my_new_board_db' AND TABLE_TYPE='BASE TABLE')>0
    AND (SELECT COUNT(1) FROM information_schema.TABLES WHERE TABLE_SCHEMA='my_new_board_db' AND TABLE_TYPE='BASE TABLE' AND ENGINE<>'InnoDB')=0,
    'SELECT 1','SELECT $guardFailure');
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
SELECT CONCAT('loop_table=',HEX(TABLE_NAME)) FROM information_schema.TABLES
WHERE TABLE_SCHEMA='my_new_board_db' AND TABLE_TYPE='BASE TABLE' ORDER BY TABLE_NAME;
"@
    $runner = Join-Path $directory 'root-file.sh'
    $sqlFile = Join-Path $directory 'preflight.sql'
    Write-BackupText $sqlFile $preflight
    $null = Invoke-BackupDocker @('exec', $state.SourceId, 'mkdir', '-p', '-m', '700', $state.TempDirectory)
    $auth = @('--user=root', '--password')
    $execArguments = @('exec', '-it', $state.SourceId)
    if ($saved) {
        $clientFile = Initialize-BackupClient $savedCredential
        $auth = @(('--defaults-file=' + $clientFile), '--no-login-paths', '--protocol=SOCKET', '--user=loop_backup')
        $execArguments = @('exec', $state.SourceId)
    }
    Write-BackupText $runner ("#!/bin/sh`nset -eu`nmysql " + ($auth -join ' ') + " --batch --skip-column-names < `"`$1`" > `"`$2`"`n")
    $null = Invoke-BackupDocker @('cp', $runner, ($state.SourceId + ':' + $state.TempDirectory + '/root-file.sh'))
    $null = Invoke-BackupDocker @('cp', $sqlFile, ($state.SourceId + ':' + $state.TempDirectory + '/preflight.sql'))
    if (-not $saved) { Write-Host 'Enter CURRENT PC2 root password for backup preflight (first prompt).' }
    Invoke-BackupDocker ($execArguments + @('sh', ($state.TempDirectory + '/root-file.sh'), ($state.TempDirectory + '/preflight.sql'), ($state.TempDirectory + '/preflight.txt')))
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
    if ($Action -eq 'PreflightSaved') {
        Save-BackupState 'preflight-passed'
        Write-Host ('PASS: ' + $SourceRole + ' backup preflight; ' + $tables.Count + ' base tables. No dump, restore or role change was performed.')
        exit 0
    }
    if (-not $saved) { Write-Host 'Enter SAME PC2 root password for mysqldump (second prompt). Do not run schema migrations during this dump.' }
    Invoke-BackupDocker ($execArguments + @('mysqldump') + $auth + @('--default-character-set=utf8mb4', '--single-transaction', '--quick', '--skip-lock-tables', '--no-tablespaces', '--routines', '--events', '--triggers', '--hex-blob', '--set-gtid-purged=OFF', ('--result-file=' + $state.TempDirectory + '/snapshot.sql'), '--databases', 'my_new_board_db'))
    $partial = Join-Path $directory 'snapshot.sql.partial'
    $null = Invoke-BackupDocker @('cp', ($state.SourceId + ':' + $state.TempDirectory + '/snapshot.sql'), $partial)
    $headers = @(Select-String -LiteralPath $partial -Pattern '^-- Table structure for table `([A-Za-z0-9_]+)`$' | ForEach-Object { $_.Matches[0].Groups[1].Value })
    if ($headers.Count -ne $tables.Count -or @(Compare-Object $headers $tables).Count -ne 0 -or @(Select-String -LiteralPath $partial -Pattern '^SET @@GLOBAL.GTID_PURGED=').Count -ne 0 -or @(Get-Content -LiteralPath $partial -Tail 5 | Select-String -Pattern '^-- Dump completed on ').Count -ne 1) { throw 'Backup is incomplete or table metadata changed. Keep partial files; no valid backup was published.' }
    $dump = Join-Path $directory 'snapshot.sql'
    [IO.File]::Move($partial, $dump)
    $manifest = [PSCustomObject]@{Format='loop-mysql84-backup-v1'; SourceRole=$SourceRole; Database='my_new_board_db'; SourceUuid=$pc2Uuid; ImageId=$state.ImageId; CreatedUtc=[DateTime]::UtcNow.ToString('o'); Tables=$tables; Length=(Get-Item $dump).Length; Sha256=(Get-FileHash $dump).Hash}
    $manifestFile = Join-Path $directory 'manifest.json'
    Write-BackupText $manifestFile ($manifest | ConvertTo-Json -Depth 6)
    $state.ManifestSha256 = (Get-FileHash $manifestFile).Hash
    }
    catch { Save-BackupState 'backup-failed'; throw }
    finally {
        $savedCredential = $null
        if ($saved) {
            $null = Invoke-BackupDocker -Arguments @('exec', $state.SourceId, 'rm', '-f', ($state.TempDirectory + '/client.cnf')) -AllowFailure
            if ($script:BackupDockerExitCode -ne 0) { Save-BackupState 'backup-failed'; throw 'Backup credential cleanup failed. No success was recorded; inspect the private client.cnf path in the backup state.' }
        }
    }
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
    # Windows bind mounts can expose mode 0777; MySQL ignores world-writable option files.
    # Copy into the container filesystem and enforce permissions there, never on the host bind.
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'mkdir', '-p', '/tmp/loop-restore-auth')
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'chmod', '700', '/tmp/loop-restore-auth')
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'cp', '/run/loop-restore/client.cnf', '/tmp/loop-restore-auth/client.cnf')
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'chmod', '600', '/tmp/loop-restore-auth/client.cnf')
    $clientMode = @(Invoke-BackupDocker @('exec', $state.TestId, 'stat', '-c', '%a', '/tmp/loop-restore-auth/client.cnf'))
    if ($clientMode.Count -ne 1 -or $clientMode[0] -cne '600') { throw 'Container-local restore client config must have mode 600. No restore SQL was executed.' }
    # Windows PowerShell 5.1 strips embedded native argument quotes. Keep shell/SQL in LF files.
    $readyScript = Join-Path $state.Directory 'restore-ready.sh'
    $readySql = Join-Path $state.Directory 'restore-ready.sql'
    Write-BackupText $readyScript @'
#!/bin/sh
set -eu
test "$(cat /proc/1/comm)" = mysqld
mysql --defaults-extra-file=/tmp/loop-restore-auth/client.cnf --batch --skip-column-names < "$1"
'@
    Write-BackupText $readySql "SELECT VERSION(),@@GLOBAL.server_id;`n"
    $null = Invoke-BackupDocker @('cp', $readyScript, ($state.TestId + ':/tmp/loop-restore-ready.sh'))
    $null = Invoke-BackupDocker @('cp', $readySql, ($state.TestId + ':/tmp/loop-restore-ready.sql'))
    $ready = $false
    for ($attempt=0; $attempt -lt 24; $attempt++) {
        $test = Get-BackupContainer $state.TestId
        Assert-TestContainer $test
        if (-not $test.State.Running) { throw 'Restore-test container stopped during initialization. Run Status.' }
        $rows = @(Invoke-BackupDocker -Arguments @('exec', $state.TestId, 'sh', '/tmp/loop-restore-ready.sh', '/tmp/loop-restore-ready.sql') -AllowFailure)
        $state | Add-Member -NotePropertyName ReadyProbeExitCode -NotePropertyValue $script:BackupDockerExitCode -Force
        if (@($rows | Where-Object { $_ -ceq "8.4.11`t9032" }).Count -eq 1) { $ready=$true; break }
        if ($attempt % 4 -eq 0) { Write-Host 'Waiting for the isolated MySQL restore-test server...' }
        Start-Sleep -Seconds 5
    }
    if (-not $ready) { throw ('Isolated MySQL did not become ready within 120 seconds. Last readiness exit code: ' + $state.ReadyProbeExitCode + '. Run Status.') }
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
    Write-BackupText $runner "#!/bin/sh`nset -eu`nmysql --defaults-extra-file=/tmp/loop-restore-auth/client.cnf --batch --skip-column-names < `"`$1`"`n"
    $null = Invoke-BackupDocker @('cp', $runner, ($state.TestId + ':/tmp/loop-restore-file.sh'))
    $null = Invoke-BackupDocker @('cp', $guardFile, ($state.TestId + ':/tmp/loop-restore-guard.sql'))
    $null = Invoke-BackupDocker @('cp', (Join-Path $state.Directory 'snapshot.sql'), ($state.TestId + ':/tmp/loop-restore-snapshot.sql'))
    Save-BackupState 'restoring'
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'sh', '/tmp/loop-restore-file.sh', '/tmp/loop-restore-guard.sql')
    $null = Invoke-BackupDocker @('exec', $state.TestId, 'sh', '/tmp/loop-restore-file.sh', '/tmp/loop-restore-snapshot.sql')
    $qualified = @($manifest.Tables | ForEach-Object { '`my_new_board_db`.`' + $_ + '`' })
    $check = $identityGuard + "`nCHECK TABLE " + ($qualified -join ',') + ";`n"
    # Batch mode escapes tabs inside a field. Emit two columns so mysql supplies the separator.
    foreach ($table in $manifest.Tables) { $check += "SELECT 'loop_rows=$table',COUNT(1) FROM ``my_new_board_db``.``$table``;`n" }
    $checkFile = Join-Path $state.Directory 'restore-check.sql'
    Write-BackupText $checkFile $check
    $null = Invoke-BackupDocker @('cp', $checkFile, ($state.TestId + ':/tmp/loop-restore-check.sql'))
    $report = @(Invoke-BackupDocker @('exec', $state.TestId, 'sh', '/tmp/loop-restore-file.sh', '/tmp/loop-restore-check.sql'))
    Write-BackupText (Join-Path $state.Directory 'restore-report.txt') ($report -join "`n")
    foreach ($table in $manifest.Tables) {
        $expected = 'my_new_board_db.' + $table + "`tcheck`tstatus`tOK"
        if (@($report | Where-Object { $_ -ceq $expected }).Count -ne 1) { throw ('Restored table check failed: ' + $table + '. Inspect the private restore-report.txt; no success was recorded.') }
        if (@($report | Where-Object { $_ -cmatch ('^loop_rows=' + [regex]::Escape($table) + '\t[0-9]+$') }).Count -ne 1) { throw ('Restored row count failed: ' + $table + '. Inspect the private restore-report.txt; no success was recorded.') }
    }
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
}
finally { $operationLock.Dispose() }
