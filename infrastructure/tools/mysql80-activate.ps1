[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [ValidateSet('Activate', 'Verify', 'Status')][string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = Join-Path $PSScriptRoot '../..'
}
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$stateFile = Join-Path $repo '.secrets/mysql80-upgrade/state.json'
$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
$utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-ActivationDocker([string[]]$Arguments) {
    & docker @Arguments
    if ($LASTEXITCODE -ne 0) { throw ('Docker ' + $Arguments[0] + ' failed. Do not repeat activation; run Status.') }
}

function Get-ActivationContainer([string]$Id) {
    $raw = @(Invoke-ActivationDocker -Arguments @('inspect', $Id))
    $items = ($raw -join "`n") | ConvertFrom-Json
    if (@($items).Count -ne 1) { throw 'Expected one container.' }
    $items[0]
}

function Save-ActivationStage([string]$Stage) {
    $state.Stage = $Stage
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 8), $utf8)
}

function Assert-ActivationVolume($Container, [string]$Volume) {
    $mounts = @($Container.Mounts)
    if ($mounts.Count -ne 1 -or $mounts[0].Type -ne 'volume' -or $mounts[0].Name -ne $Volume -or $mounts[0].Destination -ne '/var/lib/mysql' -or -not $mounts[0].RW) {
        throw 'Unexpected data mount. No further activation changes will be made.'
    }
}

function Assert-ActivationWriter([string]$Volume, [string]$ExpectedId = '') {
    $ids = @(Invoke-ActivationDocker -Arguments @('ps', '--no-trunc', '--filter', ('volume=' + $Volume), '--format', '{{.ID}}'))
    if ([string]::IsNullOrWhiteSpace($ExpectedId)) {
        if ($ids.Count -ne 0) { throw 'A protected volume is still in use.' }
    }
    elseif ($ids.Count -ne 1 -or $ids[0] -ne $ExpectedId) { throw 'Unexpected running user of the clone volume.' }
}

function Assert-ActivationPublished($Container) {
    $port = $Container.HostConfig.PortBindings.PSObject.Properties['3306/tcp']
    if ($null -eq $port -or @($port.Value).Count -ne 1 -or $port.Value[0].HostPort -ne '3306' -or $port.Value[0].HostIp -ne '0.0.0.0') {
        throw 'Unexpected production port binding.'
    }
}

if ($Action -eq 'Status') {
    Write-Host ('Stage: ' + $state.Stage)
    $ids = @($state.SourceId, $state.CandidateId)
    if ($null -ne $state.PSObject.Properties['ProductionId']) { $ids += $state.ProductionId }
    foreach ($id in $ids) {
        if (-not [string]::IsNullOrWhiteSpace($id)) {
            Invoke-ActivationDocker -Arguments @('inspect', '--format', 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} error={{json .State.Error}}', $id)
        }
    }
    Invoke-ActivationDocker -Arguments @('ps', '--filter', 'publish=3306', '--format', 'table {{.Names}}\t{{.Status}}\t{{.Ports}}')
    exit 0
}

if ($state.SourceName -ne 'flask_mysql' -or $state.SourceVolume -ne '7_test_class_mysql_data' -or $state.CloneVolume -eq $state.SourceVolume -or $state.ExpectedTables -ne 22) {
    throw 'State does not describe the confirmed PC1 upgrade.'
}
$source = Get-ActivationContainer $state.SourceId
$candidate = Get-ActivationContainer $state.CandidateId
Assert-ActivationVolume $source $state.SourceVolume
Assert-ActivationVolume $candidate $state.CloneVolume
if ($source.State.Running -or $source.State.ExitCode -ne 0 -or $source.Image -ne $state.SourceImageId) { throw 'The preserved original must remain cleanly stopped.' }
if ($candidate.Image -ne $state.TargetImageId -or $candidate.HostConfig.NetworkMode -ne 'none') { throw 'Candidate identity or isolation changed.' }
if ($source.HostConfig.RestartPolicy.Name -ne 'no' -or $candidate.HostConfig.RestartPolicy.Name -ne 'no') { throw 'Preserved containers must not restart automatically.' }
Assert-ActivationWriter $state.SourceVolume

$serverArguments = @('--server-id=1', '--lower-case-table-names=0', '--innodb-page-size=16384', '--character-set-server=utf8mb4', '--collation-server=utf8mb4_0900_ai_ci', '--innodb-buffer-pool-size=256M', '--event-scheduler=OFF')
if ((@($candidate.Config.Cmd) -join "`n") -cne ($serverArguments -join "`n")) { throw 'Candidate server arguments changed.' }

$guardSql = @'
SET @loop_guard = IF(
    VERSION() = '8.4.11' AND @@GLOBAL.server_id = 1
    AND @@GLOBAL.lower_case_table_names = 0 AND @@GLOBAL.innodb_page_size = 16384
    AND @@GLOBAL.persisted_globals_load = 1
    AND (SELECT COUNT(1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE') = 22
    AND (SELECT COUNT(1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB') = 0
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration) = 0,
    'SELECT 1', 'SELECT UPGRADE_ACTIVATION_STATE_CHANGED'
);
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
'@

if ($Action -eq 'Activate') {
    if ($state.Stage -ne 'candidate-started') { throw 'Activation stage is not candidate-started. Do not repeat; run Status.' }
    if ($source.Name -ne '/flask_mysql' -or -not $candidate.State.Running -or $candidate.Name -ne ('/' + $state.CandidateName)) { throw 'Source or candidate name/state changed.' }
    Assert-ActivationWriter $state.CloneVolume $state.CandidateId
    $publishers = @(Invoke-ActivationDocker -Arguments @('ps', '--filter', 'publish=3306', '--format', '{{.ID}}'))
    if ($publishers.Count -ne 0) { throw 'Port 3306 is already published by another running container. Nothing was stopped.' }
    if (@(Get-NetTCPConnection -State Listen -LocalPort 3306 -ErrorAction SilentlyContinue).Count -ne 0) { throw 'Windows port 3306 is busy. Nothing was stopped.' }
    $nameConflict = @(Invoke-ActivationDocker -Arguments @('ps', '-a', '--filter', ('name=^/' + $state.RollbackName + '$'), '--format', '{{.ID}}'))
    if ($nameConflict.Count -ne 0) { throw 'Rollback container name is already in use.' }
    $backupHash = (Get-FileHash -LiteralPath $state.BackupFile -Algorithm SHA256).Hash
    if ($backupHash -cne ([IO.File]::ReadAllText($state.BackupFile + '.sha256')).Trim()) { throw 'Preserved SQL backup hash mismatch.' }

    Save-ActivationStage 'activation-checking'
    Write-Host 'Enter the existing PC1 root password. Flask and other DB writers must remain stopped.'
    $freezeSql = $guardSql + "`nSET PERSIST read_only = ON;`nSET PERSIST super_read_only = ON;`nSET GLOBAL innodb_fast_shutdown = 0;"
    Invoke-ActivationDocker -Arguments @('exec', '-it', $state.CandidateId, 'mysql', '--user=root', '--password', ('--execute=' + $freezeSql))
    Save-ActivationStage 'candidate-checked'
    $null = Invoke-ActivationDocker -Arguments @('stop', '--time', '180', $state.CandidateId)
    $candidate = Get-ActivationContainer $state.CandidateId
    if ($candidate.State.Running -or $candidate.State.ExitCode -ne 0) { throw 'Candidate did not stop cleanly. Original remains preserved.' }
    Assert-ActivationWriter $state.SourceVolume
    Assert-ActivationWriter $state.CloneVolume
    Save-ActivationStage 'candidate-stopped'

    Save-ActivationStage 'renaming-original'
    $null = Invoke-ActivationDocker -Arguments @('rename', $state.SourceId, $state.RollbackName)
    Save-ActivationStage 'original-renamed'
    $createArguments = @('create', '--name', 'flask_mysql', '--restart=no', '--network', 'bridge', '--memory', '2g', '--publish', '0.0.0.0:3306:3306', '--mount', ('type=volume,source=' + $state.CloneVolume + ',target=/var/lib/mysql'), $state.TargetImageId) + $serverArguments
    $created = Invoke-ActivationDocker -Arguments $createArguments
    $state | Add-Member -NotePropertyName ProductionId -NotePropertyValue (($created -join '').Trim()) -Force
    Save-ActivationStage 'production-created'
    $production = Get-ActivationContainer $state.ProductionId
    Assert-ActivationVolume $production $state.CloneVolume
    Assert-ActivationPublished $production
    if ($production.Image -ne $state.TargetImageId -or $production.Name -ne '/flask_mysql' -or $production.HostConfig.NetworkMode -ne 'bridge' -or (@($production.Config.Cmd) -join "`n") -cne ($serverArguments -join "`n")) { throw 'Production container identity or arguments changed. It has not been started.' }
    $null = Invoke-ActivationDocker -Arguments @('start', $state.ProductionId)
    Save-ActivationStage 'production-started'
    Write-Host 'PASS: MySQL 8.4 service start requested on port 3306. Original container and volume preserved.'
    Write-Host 'Keep Flask stopped. Run Verify after MySQL becomes ready; do not repeat Activate.'
    exit 0
}

if ($state.Stage -notin @('production-started', 'service-ready')) { throw 'There is no started production service to verify. Run Status.' }
$production = Get-ActivationContainer $state.ProductionId
Assert-ActivationVolume $production $state.CloneVolume
Assert-ActivationPublished $production
if ($candidate.State.Running -or -not $production.State.Running -or $production.Image -ne $state.TargetImageId -or $production.Name -ne '/flask_mysql' -or $production.HostConfig.NetworkMode -ne 'bridge') { throw 'Unexpected production or candidate runtime state.' }
Assert-ActivationWriter $state.CloneVolume $state.ProductionId
$publisherIds = @(Invoke-ActivationDocker -Arguments @('ps', '--no-trunc', '--filter', 'publish=3306', '--format', '{{.ID}}'))
if ($publisherIds.Count -ne 1 -or $publisherIds[0] -ne $state.ProductionId) { throw 'Port 3306 is not exclusively served by the upgraded container.' }
Write-Host 'Enter the existing PC1 root password to verify the upgraded primary.'
$writeGuard = @'
SET PERSIST super_read_only = OFF;
SET PERSIST read_only = OFF;
SET @loop_write_guard = IF(@@GLOBAL.read_only = 0 AND @@GLOBAL.super_read_only = 0,
    'SELECT 1', 'SELECT PRIMARY_WRITE_STATE_CHANGED');
PREPARE loop_write_statement FROM @loop_write_guard;
EXECUTE loop_write_statement;
DEALLOCATE PREPARE loop_write_statement;
SELECT VERSION() AS mysql_version, @@GLOBAL.server_id AS server_id,
       @@GLOBAL.read_only AS read_only, @@GLOBAL.super_read_only AS super_read_only;
SELECT COUNT(1) AS base_table_count FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE';
'@
$verifySql = $guardSql + "`n" + $writeGuard
Invoke-ActivationDocker -Arguments @('exec', '-it', $state.ProductionId, 'mysql', '--user=root', '--password', ('--execute=' + $verifySql))
$null = Invoke-ActivationDocker -Arguments @('update', '--restart=unless-stopped', $state.ProductionId)
Save-ActivationStage 'service-ready'
Write-Host 'PASS: MySQL 8.4.11, 22 InnoDB tables, primary writes enabled, restart policy saved.'
Write-Host 'Next verify Windows 127.0.0.1:3306 and Flask login/read/write. Replication is not configured yet.'
