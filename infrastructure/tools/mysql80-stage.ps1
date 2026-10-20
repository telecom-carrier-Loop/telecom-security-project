[CmdletBinding()]
param([string]$RepositoryPath)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '../..'
}
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$private = Join-Path $repo '.secrets/mysql80-upgrade'
$stateFile = Join-Path $private 'state.json'
$utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-StageDocker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Docker ' + $Arguments[0] + ' failed. Stop; do not repeat staging.') }
}

function Get-StageContainer([string]$Name) {
    $raw = @(Invoke-StageDocker -Arguments @('inspect', $Name))
    $items = ($raw -join "`n") | ConvertFrom-Json
    if (@($items).Count -ne 1) { throw 'Expected one container.' }
    $items[0]
}

function Save-StageState {
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 6), $utf8)
}

if (Test-Path -LiteralPath $stateFile) { throw 'Upgrade state already exists. Do not repeat staging; report the saved Stage.' }
$source = Get-StageContainer 'flask_mysql'
$data = @($source.Mounts | Where-Object Destination -eq '/var/lib/mysql')
if (-not $source.State.Running -or $source.Name -ne '/flask_mysql') { throw 'The actual flask_mysql source must be running.' }
if ($data.Count -ne 1 -or $data[0].Type -ne 'volume' -or $data[0].Name -ne '7_test_class_mysql_data' -or -not $data[0].RW) {
    throw 'The actual source volume differs from the confirmed PC1 volume.'
}
if ($source.Mounts.Count -ne 1 -or $source.HostConfig.NetworkMode -ne 'bridge' -or @($source.Config.Cmd).Count -ne 1 -or $source.Config.Cmd[0] -ne 'mysqld') {
    throw 'Source configuration changed. Review custom mounts, networks or server arguments before staging.'
}
$port = $source.NetworkSettings.Ports.PSObject.Properties['3306/tcp']
$published = $false
if ($null -ne $port) {
    foreach ($binding in @($port.Value)) {
        if ($null -ne $binding -and $binding.HostPort -eq '3306' -and $binding.HostIp -in @('', '0.0.0.0', '127.0.0.1', '::')) { $published = $true }
    }
}
if (-not $published) { throw 'flask_mysql is not the actual 3306 database publisher.' }
$writers = @(Invoke-StageDocker -Arguments @('ps', '--no-trunc', '--filter', ('volume=' + $data[0].Name), '--format', '{{.ID}}'))
if ($writers.Count -ne 1 -or $writers[0] -ne $source.Id) { throw 'Another running container uses the source data volume.' }

# Download before changing the source or taking it offline.
$null = Invoke-StageDocker -Arguments @('pull', 'mysql:8.4.11')
$imageId = (Invoke-StageDocker -Arguments @('image', 'inspect', '--format', '{{.Id}}', 'mysql:8.4.11')).Trim()
$tag = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$work = Join-Path $private $tag
$null = New-Item -ItemType Directory -Path $work -Force
$state = [PSCustomObject]@{
    Stage = 'preparing'; SourceId = $source.Id; SourceName = 'flask_mysql'
    SourceVolume = $data[0].Name; SourceRestartPolicy = $source.HostConfig.RestartPolicy
    SourceImageId = $source.Image; TargetImageId = $imageId
    CandidateName = ('loop-pc1-mysql84-' + $tag); CandidateId = ''
    CloneVolume = ('loop-pc1-mysql84-data-' + $tag)
    BackupFile = (Join-Path $work ('pc1-mysql80-my_new_board_db-' + $tag + '.sql'))
    ExpectedTables = 22; RollbackName = ('flask_mysql-80-rollback-' + $tag)
}
Save-StageState

# Interactive commands must not capture stdout: the password prompt must remain visible.
$guardSql = @'
SET @loop_guard = IF(
    VERSION() = '8.0.46'
    AND @@GLOBAL.lower_case_table_names = 0
    AND @@GLOBAL.innodb_page_size = 16384
    AND @@GLOBAL.gtid_mode = 'OFF'
    AND (SELECT COUNT(1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE') = 22
    AND (SELECT COUNT(1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB') = 0
    AND (SELECT COUNT(1) FROM mysql.user WHERE plugin <> 'caching_sha2_password') = 0
    AND (SELECT COUNT(1) FROM information_schema.EVENTS) = 0
    AND (SELECT COUNT(1) FROM information_schema.INNODB_TABLESPACES WHERE ENCRYPTION = 'Y') = 0
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration) = 0,
    'SELECT 1', 'SELECT UPGRADE_SOURCE_STATE_CHANGED'
);
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
SET GLOBAL super_read_only = ON;
SET GLOBAL innodb_fast_shutdown = 0;
SELECT 'PASS: source checked and writes paused' AS source_check;
'@
Write-Host 'Enter the CURRENT flask_mysql root password for source checks (first prompt).'
Invoke-StageDocker -Arguments @('exec', '-it', $source.Id, 'mysql', '--user=root', '--password', ('--execute=' + $guardSql))
$state.Stage = 'source-frozen'; Save-StageState

$containerDump = '/tmp/loop-mysql80-' + $tag + '.sql'
Write-Host 'Enter the SAME current root password for the full app DB backup (second prompt).'
Invoke-StageDocker -Arguments @('exec', '-it', $source.Id, 'mysqldump', '--user=root', '--password', '--default-character-set=utf8mb4', '--single-transaction', '--quick', '--routines', '--events', '--triggers', '--hex-blob', '--no-tablespaces', '--set-gtid-purged=OFF', ('--result-file=' + $containerDump), '--databases', 'my_new_board_db')
$null = Invoke-StageDocker -Arguments @('cp', ($source.Id + ':' + $containerDump), $state.BackupFile)
if ((Get-Item -LiteralPath $state.BackupFile).Length -eq 0) { throw 'Backup is empty. Original has not been stopped.' }
$tableHeaders = @(Select-String -LiteralPath $state.BackupFile -Pattern '^-- Table structure for table ')
if ($tableHeaders.Count -ne 22) { throw 'Backup does not contain the confirmed 22 tables. Original has not been stopped.' }
$hash = (Get-FileHash -LiteralPath $state.BackupFile -Algorithm SHA256).Hash
[IO.File]::WriteAllText(($state.BackupFile + '.sha256'), $hash, [Text.Encoding]::ASCII)
$state.Stage = 'backup-complete'; Save-StageState

$null = Invoke-StageDocker -Arguments @('update', '--restart=no', $source.Id)
$null = Invoke-StageDocker -Arguments @('stop', '--time', '180', $source.Id)
$stopped = Get-StageContainer $source.Id
if ($stopped.State.Running -or $stopped.State.ExitCode -ne 0) { throw 'Original did not shut down cleanly. Do not copy or upgrade its data.' }
$state.Stage = 'source-stopped'; Save-StageState

$null = Invoke-StageDocker -Arguments @('volume', 'create', $state.CloneVolume)
$state.Stage = 'copying'; Save-StageState
$null = Invoke-StageDocker -Arguments @('run', '--rm', '--network', 'none', '--user', '0', '--mount', ('type=volume,source=' + $state.SourceVolume + ',target=/from,readonly'), '--mount', ('type=volume,source=' + $state.CloneVolume + ',target=/to'), '--entrypoint', '/bin/sh', $imageId, '-c', 'cp -a /from/. /to/')
$state.Stage = 'copied'; Save-StageState

# Only the new clone is opened by 8.4. No host ports are published.
$created = Invoke-StageDocker -Arguments @('create', '--name', $state.CandidateName, '--restart=no', '--network', 'none', '--memory', '2g', '--mount', ('type=volume,source=' + $state.CloneVolume + ',target=/var/lib/mysql'), $imageId, '--server-id=1', '--lower-case-table-names=0', '--innodb-page-size=16384', '--character-set-server=utf8mb4', '--collation-server=utf8mb4_0900_ai_ci', '--innodb-buffer-pool-size=256M', '--event-scheduler=OFF')
$state.CandidateId = ($created -join '').Trim()
$candidate = Get-StageContainer $state.CandidateId
$candidateData = @($candidate.Mounts | Where-Object Destination -eq '/var/lib/mysql')
if ($candidateData.Count -ne 1 -or $candidateData[0].Name -ne $state.CloneVolume -or $candidateData[0].Name -eq $state.SourceVolume -or -not $candidateData[0].RW -or $candidate.HostConfig.NetworkMode -ne 'none' -or $candidate.Image -ne $imageId) {
    throw 'Candidate safety check failed. It has not been started.'
}
$state.Stage = 'candidate-created'; Save-StageState
$null = Invoke-StageDocker -Arguments @('start', $state.CandidateId)
$state.Stage = 'candidate-started'; Save-StageState
Write-Host 'PASS: original preserved, 22-table SQL backup saved, MySQL 8.4.11 candidate start requested on the clone.'
Write-Host 'Validation is still required. Flask must remain stopped; the candidate has no published ports.'
Write-Host ('Candidate: ' + $state.CandidateName)
Write-Host ('Backup: ' + $state.BackupFile)
