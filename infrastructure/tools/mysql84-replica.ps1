[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [ValidateSet('Stage', 'Restore', 'Activate', 'Start', 'Verify', 'Status')][string]$Action = 'Status',
    [string]$ManifestSha256
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { $RepositoryPath = Join-Path $PSScriptRoot '../..' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$private = Join-Path $repo '.secrets/mysql84-replication/pc2'
$stateFile = Join-Path $private 'state.json'
$incoming = Join-Path $repo '.secrets/mysql84-replication/incoming/pc2-transfer'
$utf8 = [Text.UTF8Encoding]::new($false)
$pc2Uuid = 'f1868a2a-a5a5-11f1-8815-9693e922f083'
$serverArguments = @('--server-id=2', '--gtid-mode=ON', '--enforce-gtid-consistency=ON', '--replicate-do-db=my_new_board_db', '--skip-replica-start=OFF', '--innodb-buffer-pool-size=256M', '--event-scheduler=OFF')

function Invoke-ReplicaDocker([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Arguments -contains '-it') { & docker @Arguments; $code = $LASTEXITCODE; $lines = @() }
        else { $lines = @(& docker @Arguments 2>&1); $code = $LASTEXITCODE }
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) { throw ('Docker ' + $Arguments[0] + ' failed. Keep the original; run Status instead of repeating Stage or Activate.') }
    foreach ($line in $lines) { $line.ToString() }
}

function Get-ReplicaContainer([string]$Id) {
    $raw = @(Invoke-ReplicaDocker -Arguments @('inspect', $Id))
    $items = ($raw -join "`n") | ConvertFrom-Json
    if (@($items).Count -ne 1) { throw 'Expected one container.' }
    $items[0]
}

function Write-ReplicaText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
}

function Save-ReplicaStage([string]$Stage) {
    $state.Stage = $Stage
    Write-ReplicaText $stateFile ($state | ConvertTo-Json -Depth 8)
}

function Assert-ReplicaMount($Container, [string]$Volume) {
    $mounts = @($Container.Mounts)
    if ($mounts.Count -ne 1 -or $mounts[0].Type -ne 'volume' -or $mounts[0].Name -ne $Volume -or $mounts[0].Destination -ne '/var/lib/mysql' -or -not $mounts[0].RW) { throw 'Unexpected data mount. Nothing further will be changed.' }
}

function Assert-ReplicaWriters([string]$Volume, [string]$ExpectedId = '') {
    $ids = @(Invoke-ReplicaDocker -Arguments @('ps', '--no-trunc', '--filter', ('volume=' + $Volume), '--format', '{{.ID}}'))
    if ([string]::IsNullOrWhiteSpace($ExpectedId)) {
        if ($ids.Count -ne 0) { throw 'A preserved volume still has a running user.' }
    }
    elseif ($ids.Count -ne 1 -or $ids[0] -ne $ExpectedId) { throw 'Unexpected shared use of the replica volume.' }
}

function Get-ReplicaPassword {
    $seed = [IO.File]::ReadAllText((Join-Path $incoming 'replication-password')).Trim()
    if ($seed -notmatch '^(Lp9![a-f0-9]{28}|(Lp9!)?[a-f0-9]{64})$') { throw 'Unexpected replication credential format.' }
    # Legacy bundles keep their original hashes; PC1 FixReplicationPassword applies the same prefix.
    $seed.Substring(0, 32)
}

function Set-ReplicaClient([string]$Id) {
    $credential = Get-ReplicaPassword
    $client = @"
[client]
user=loop_repl
password=$credential
host=192.168.3.18
port=3306
protocol=TCP
ssl-mode=VERIFY_IDENTITY
ssl-ca=$($state.TlsDirectory)/ca.pem
ssl-cert=$($state.TlsDirectory)/client-cert.pem
ssl-key=$($state.TlsDirectory)/client-key.pem
"@
    $clientFile = Join-Path $private 'primary-client.cnf'
    Write-ReplicaText $clientFile $client
    $null = Invoke-ReplicaDocker -Arguments @('cp', $clientFile, ($Id + ':' + $state.TlsDirectory + '/client.cnf'))
    $null = Invoke-ReplicaDocker -Arguments @('exec', $Id, 'chmod', '600', ($state.TlsDirectory + '/client.cnf'))
}

function Read-ReplicaBundle([string]$TrustedHash) {
    if ($TrustedHash -notmatch '^[a-fA-F0-9]{64}$') { throw 'A 64-character SHA256 copied from PC1 is required.' }
    $manifestPath = Join-Path $incoming 'manifest.json'
    if ((Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash -ine $TrustedHash) { throw 'Manifest SHA256 does not match PC1. No DB changes allowed.' }
    $bundle = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($bundle.Format -ne 'loop-mysql84-seed-v1' -or $bundle.PrimaryAddress -ne '192.168.3.18' -or $bundle.PrimaryPort -ne 3306 -or $bundle.PrimaryServerId -ne 1 -or $bundle.Database -ne 'my_new_board_db' -or $bundle.MySqlVersion -ne '8.4.11' -or $bundle.ExpectedTables -ne 22 -or $bundle.PrimaryUuid -notmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or $bundle.PrimaryUuid -eq $pc2Uuid) { throw 'Unexpected PC1 bundle identity.' }
    $expected = @('snapshot.sql', 'ca.pem', 'client-cert.pem', 'client-key.pem', 'replication-password')
    if (@($bundle.Files).Count -ne 5) { throw 'Unexpected manifest file count.' }
    foreach ($name in $expected) {
        $entries = @($bundle.Files | Where-Object Path -ceq $name)
        if ($entries.Count -ne 1) { throw 'Unexpected or duplicate manifest path.' }
        $path = Join-Path $incoming $name
        $item = Get-Item -LiteralPath $path
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $item.Length -eq 0 -or $item.Length -ne $entries[0].Length -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $entries[0].Sha256) { throw ('Transfer file integrity check failed: ' + $name) }
    }
    $null = Get-ReplicaPassword
    $bundle
}

function Invoke-ReplicaSql([string]$Id, [string]$Name, [string]$Sql, [string]$ExistingFile = '') {
    $file = Join-Path $private ($Name + '.sql')
    if (-not [string]::IsNullOrWhiteSpace($ExistingFile)) { $file = $ExistingFile }
    else { Write-ReplicaText $file $Sql }
    $runner = Join-Path $private 'root-file.sh'
    Write-ReplicaText $runner "#!/bin/sh`nset -eu`nmysql --user=root --password < `"`$1`"`n"
    $null = Invoke-ReplicaDocker -Arguments @('exec', $Id, 'mkdir', '-p', '-m', '700', $state.TempDirectory)
    $sqlPath = $state.TempDirectory + '/' + $Name + '.sql'
    $null = Invoke-ReplicaDocker -Arguments @('cp', $runner, ($Id + ':' + $state.TempDirectory + '/root-file.sh'))
    $null = Invoke-ReplicaDocker -Arguments @('cp', $file, ($Id + ':' + $sqlPath))
    Write-Host ('Enter the CURRENT PC2 root password: ' + $Name)
    Invoke-ReplicaDocker -Arguments @('exec', '-it', $Id, 'sh', ($state.TempDirectory + '/root-file.sh'), $sqlPath)
    $null = Invoke-ReplicaDocker -Arguments @('exec', $Id, 'rm', '-f', $sqlPath)
}

$identityGuard = @"
SET @loop_guard = IF(
    VERSION() = '8.4.11' AND @@GLOBAL.server_id = 2
    AND @@GLOBAL.server_uuid = '$pc2Uuid'
    AND @@GLOBAL.gtid_mode = 'ON' AND @@GLOBAL.enforce_gtid_consistency = 'ON'
    AND @@GLOBAL.log_bin = 1 AND @@GLOBAL.log_replica_updates = 1
    AND @@GLOBAL.datadir = '/var/lib/mysql/' AND @@GLOBAL.persisted_globals_load = 1,
    'SELECT 1', 'SELECT PC2_REPLICA_IDENTITY_CHANGED'
);
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
"@
$emptyChannelGuard = @'
SET @loop_channel_guard = IF(
    (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration) = 0,
    'SELECT 1', 'SELECT EXISTING_REPLICATION_CHANNEL');
PREPARE loop_channel_statement FROM @loop_channel_guard;
EXECUTE loop_channel_statement;
DEALLOCATE PREPARE loop_channel_statement;
'@
$tableGuard = @'
SET @loop_table_guard = IF(
    (SELECT COUNT(1) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE') = 22
    AND (SELECT COUNT(1) FROM information_schema.TABLES WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB') = 0,
    'SELECT 1', 'SELECT RESTORED_TABLES_MISMATCH');
PREPARE loop_table_statement FROM @loop_table_guard;
EXECUTE loop_table_statement;
DEALLOCATE PREPARE loop_table_statement;
'@

if ($Action -eq 'Status') {
    if (-not (Test-Path -LiteralPath $stateFile)) { Write-Host 'No PC2 staging state exists.'; exit 0 }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Write-Host ('Stage: ' + $state.Stage)
    $ids = @($state.SourceId, $state.CandidateId)
    if ($null -ne $state.PSObject.Properties['ProductionId']) { $ids += $state.ProductionId }
    foreach ($id in $ids) {
        if (-not [string]::IsNullOrWhiteSpace($id)) { Invoke-ReplicaDocker -Arguments @('inspect', '--format', 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} error={{json .State.Error}}', $id) }
    }
    exit 0
}

if ($Action -eq 'Stage') {
    if (Test-Path -LiteralPath $private) { throw 'PC2 staging files already exist. Do not repeat Stage; run Status.' }
    if ([string]::IsNullOrWhiteSpace($ManifestSha256)) { $ManifestSha256 = Read-Host 'Paste MANIFEST_SHA256 copied from PC1' }
    $bundle = Read-ReplicaBundle $ManifestSha256
    $source = Get-ReplicaContainer 'mysql-lab'
    if ($source.Name -ne '/mysql-lab' -or -not $source.State.Running -or $source.HostConfig.NetworkMode -ne 'bridge' -or (@($source.Config.Cmd) -join '') -ne 'mysqld') { throw 'Actual PC2 mysql-lab configuration changed.' }
    $data = @($source.Mounts)
    if ($data.Count -ne 1 -or $data[0].Type -ne 'volume' -or [string]::IsNullOrWhiteSpace($data[0].Name)) { throw 'Expected the confirmed single PC2 named data volume.' }
    Assert-ReplicaMount $source $data[0].Name
    $port = $source.HostConfig.PortBindings.PSObject.Properties['3306/tcp']
    if ($null -eq $port -or @($port.Value).Count -ne 1 -or $port.Value[0].HostPort -ne '3306' -or $port.Value[0].HostIp -notin @('', '0.0.0.0')) { throw 'PC2 source is not the confirmed 3306 publisher.' }
    Assert-ReplicaWriters $data[0].Name $source.Id
    $null = New-Item -ItemType Directory -Path $private
    $tag = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
    $state = [PSCustomObject]@{
        Stage = 'preparing'; SourceId = $source.Id; SourceVolume = $data[0].Name; ImageId = $source.Image
        SourceRestartPolicy = $source.HostConfig.RestartPolicy
        CloneVolume = ('loop-pc2-replica-data-' + $tag); CandidateName = ('loop-pc2-seed-' + $tag); CandidateId = ''
        RollbackName = ('mysql-lab-before-replication-' + $tag)
        TempDirectory = ('/tmp/loop-replica-' + $tag); TlsDirectory = ('/var/lib/mysql/.loop-replica-' + $tag)
        ManifestSha256 = $ManifestSha256.ToUpperInvariant(); PrimaryUuid = $bundle.PrimaryUuid
    }
    Save-ReplicaStage 'preparing'
    Invoke-ReplicaSql $source.Id 'source-preflight' ($identityGuard + "`n" + $emptyChannelGuard + "`n" + $tableGuard + "`nSET GLOBAL super_read_only = ON;`nSET GLOBAL innodb_fast_shutdown = 0;")
    Save-ReplicaStage 'source-frozen'
    $null = Invoke-ReplicaDocker -Arguments @('update', '--restart=no', $source.Id)
    $null = Invoke-ReplicaDocker -Arguments @('stop', '--time', '180', $source.Id)
    $source = Get-ReplicaContainer $state.SourceId
    if ($source.State.Running -or $source.State.ExitCode -ne 0) { throw 'Original PC2 did not stop cleanly. No volume copy permitted.' }
    Assert-ReplicaWriters $state.SourceVolume
    Save-ReplicaStage 'source-stopped'
    $null = Invoke-ReplicaDocker -Arguments @('volume', 'create', $state.CloneVolume)
    Save-ReplicaStage 'copying'
    $null = Invoke-ReplicaDocker -Arguments @('run', '--rm', '--network', 'none', '--user', '0', '--mount', ('type=volume,source=' + $state.SourceVolume + ',target=/from,readonly'), '--mount', ('type=volume,source=' + $state.CloneVolume + ',target=/to'), '--entrypoint', '/bin/sh', $state.ImageId, '-c', 'cp -a /from/. /to/')
    $created = Invoke-ReplicaDocker -Arguments (@('create', '--name', $state.CandidateName, '--restart=no', '--network', 'none', '--memory', '2g', '--mount', ('type=volume,source=' + $state.CloneVolume + ',target=/var/lib/mysql'), $state.ImageId) + $serverArguments)
    $state.CandidateId = ($created -join '').Trim()
    Save-ReplicaStage 'candidate-created'
    $candidate = Get-ReplicaContainer $state.CandidateId
    Assert-ReplicaMount $candidate $state.CloneVolume
    if ($candidate.Image -ne $state.ImageId -or $candidate.HostConfig.NetworkMode -ne 'none' -or $state.CloneVolume -eq $state.SourceVolume) { throw 'Unsafe candidate. It has not been started.' }
    $null = Invoke-ReplicaDocker -Arguments @('start', $state.CandidateId)
    Save-ReplicaStage 'candidate-started'
    Write-Host 'PASS: PC2 original container/volume preserved. Isolated copy started. Next run Restore; do not repeat Stage.'
    exit 0
}

$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
$bundle = Read-ReplicaBundle $state.ManifestSha256
if ($state.PrimaryUuid -ne $bundle.PrimaryUuid -or $state.SourceVolume -eq $state.CloneVolume) { throw 'State and bundle identity mismatch.' }
$source = Get-ReplicaContainer $state.SourceId
$candidate = Get-ReplicaContainer $state.CandidateId
Assert-ReplicaMount $source $state.SourceVolume
Assert-ReplicaMount $candidate $state.CloneVolume
if ($source.State.Running -or $source.State.ExitCode -ne 0 -or $source.HostConfig.RestartPolicy.Name -ne 'no' -or $source.Image -ne $state.ImageId) { throw 'Preserved original is not safely stopped.' }
Assert-ReplicaWriters $state.SourceVolume
if ($candidate.Image -ne $state.ImageId -or $candidate.HostConfig.NetworkMode -ne 'none' -or $candidate.HostConfig.RestartPolicy.Name -ne 'no' -or (@($candidate.Config.Cmd) -join "`n") -cne ($serverArguments -join "`n")) { throw 'Candidate configuration changed.' }

if ($Action -eq 'Restore') {
    if ($state.Stage -notin @('candidate-started', 'restoring') -or -not $candidate.State.Running) { throw 'Restore requires the isolated running candidate.' }
    Assert-ReplicaWriters $state.CloneVolume $state.CandidateId
    $null = Invoke-ReplicaDocker -Arguments @('exec', $state.CandidateId, 'mkdir', '-p', '-m', '700', $state.TlsDirectory)
    foreach ($file in @('ca.pem', 'client-cert.pem', 'client-key.pem')) {
        $null = Invoke-ReplicaDocker -Arguments @('cp', (Join-Path $incoming $file), ($state.CandidateId + ':' + $state.TlsDirectory + '/' + $file))
        $null = Invoke-ReplicaDocker -Arguments @('exec', $state.CandidateId, 'chown', 'mysql:mysql', ($state.TlsDirectory + '/' + $file))
        $null = Invoke-ReplicaDocker -Arguments @('exec', $state.CandidateId, 'chmod', '600', ($state.TlsDirectory + '/' + $file))
    }
    $null = Invoke-ReplicaDocker -Arguments @('exec', $state.CandidateId, 'chown', 'mysql:mysql', $state.TlsDirectory)
    Set-ReplicaClient $state.CandidateId
    $restoreFile = Join-Path $private 'restore.sql'
    $writer = [IO.StreamWriter]::new($restoreFile, $false, $utf8)
    try {
        $writer.WriteLine($identityGuard)
        $writer.WriteLine($emptyChannelGuard)
        $writer.WriteLine("SET GLOBAL super_read_only = OFF;`nSET GLOBAL read_only = OFF;`nSET SESSION sql_log_bin = 0;`nRESET BINARY LOGS AND GTIDS;`nDROP DATABASE IF EXISTS my_new_board_db;")
        $reader = [IO.StreamReader]::new((Join-Path $incoming 'snapshot.sql'))
        try { while ($null -ne ($line = $reader.ReadLine())) { $writer.WriteLine($line) } }
        finally { $reader.Dispose() }
        $writer.WriteLine($tableGuard)
        $writer.WriteLine('SET PERSIST read_only = ON;')
        $writer.WriteLine('SET PERSIST super_read_only = ON;')
    }
    finally { $writer.Dispose() }
    Save-ReplicaStage 'restoring'
    Invoke-ReplicaSql $state.CandidateId 'restore' '' $restoreFile
    Save-ReplicaStage 'restored'
    Write-Host 'PASS: snapshot restored only into the isolated clone; PC2 root account preserved; replica writes locked.'
    exit 0
}

if ($Action -eq 'Activate') {
    if ($state.Stage -ne 'restored' -or -not $candidate.State.Running -or $source.Name -ne '/mysql-lab') { throw 'Activate requires the restored candidate and original mysql-lab name.' }
    Assert-ReplicaWriters $state.CloneVolume $state.CandidateId
    if (@(Invoke-ReplicaDocker -Arguments @('ps', '--filter', 'publish=3306', '--format', '{{.ID}}')).Count -ne 0 -or @(Get-NetTCPConnection -State Listen -LocalPort 3306 -ErrorAction SilentlyContinue).Count -ne 0) { throw 'PC2 port 3306 is busy. No container was stopped by this action.' }
    if (@(Invoke-ReplicaDocker -Arguments @('ps', '-a', '--filter', ('name=^/' + $state.RollbackName + '$'), '--format', '{{.ID}}')).Count -ne 0) { throw 'Rollback name is already in use.' }
    $null = Invoke-ReplicaDocker -Arguments @('stop', '--time', '180', $state.CandidateId)
    $candidate = Get-ReplicaContainer $state.CandidateId
    if ($candidate.State.Running -or $candidate.State.ExitCode -ne 0) { throw 'Candidate shutdown was not clean.' }
    Assert-ReplicaWriters $state.CloneVolume
    Assert-ReplicaWriters $state.SourceVolume
    Save-ReplicaStage 'renaming-original'
    $null = Invoke-ReplicaDocker -Arguments @('rename', $state.SourceId, $state.RollbackName)
    Save-ReplicaStage 'original-renamed'
    $created = Invoke-ReplicaDocker -Arguments (@('create', '--name', 'mysql-lab', '--restart=no', '--network', 'bridge', '--memory', '2g', '--publish', '0.0.0.0:3306:3306', '--mount', ('type=volume,source=' + $state.CloneVolume + ',target=/var/lib/mysql'), $state.ImageId) + $serverArguments)
    $state | Add-Member -NotePropertyName ProductionId -NotePropertyValue (($created -join '').Trim()) -Force
    Save-ReplicaStage 'production-created'
    $production = Get-ReplicaContainer $state.ProductionId
    Assert-ReplicaMount $production $state.CloneVolume
    if ($production.Image -ne $state.ImageId -or $production.Name -ne '/mysql-lab' -or $production.HostConfig.NetworkMode -ne 'bridge' -or (@($production.Config.Cmd) -join "`n") -cne ($serverArguments -join "`n")) { throw 'Unsafe production identity. It has not been started.' }
    $port = $production.HostConfig.PortBindings.PSObject.Properties['3306/tcp']
    if ($null -eq $port -or @($port.Value).Count -ne 1 -or $port.Value[0].HostPort -ne '3306' -or $port.Value[0].HostIp -ne '0.0.0.0') { throw 'Unsafe production port binding. It has not been started.' }
    $null = Invoke-ReplicaDocker -Arguments @('start', $state.ProductionId)
    Save-ReplicaStage 'production-started'
    Write-Host 'PASS: restored mysql-lab started on PC2 port 3306. Next run Start after MySQL is ready.'
    exit 0
}

if ($state.Stage -notin @('production-started', 'replication-starting', 'replication-started', 'replica-ready')) { throw 'There is no activated replica to start or verify.' }
$production = Get-ReplicaContainer $state.ProductionId
Assert-ReplicaMount $production $state.CloneVolume
if ($candidate.State.Running -or -not $production.State.Running -or $production.Image -ne $state.ImageId -or $production.Name -ne '/mysql-lab' -or $production.HostConfig.NetworkMode -ne 'bridge' -or (@($production.Config.Cmd) -join "`n") -cne ($serverArguments -join "`n")) { throw 'Activated replica runtime identity changed.' }
Assert-ReplicaWriters $state.CloneVolume $state.ProductionId
# The client config was copied only to the new data volume; it contains no root credential.
Set-ReplicaClient $state.ProductionId
$remote = @(Invoke-ReplicaDocker -Arguments @('exec', $state.ProductionId, 'mysql', ('--defaults-extra-file=' + $state.TlsDirectory + '/client.cnf'), '--batch', '--skip-column-names', "--execute=SELECT CONCAT('loop_uuid=',@@GLOBAL.server_uuid); SELECT CONCAT('loop_gtid_hex=',HEX(@@GLOBAL.gtid_executed));"))
$uuidRows = @($remote | Where-Object { $_ -ceq ('loop_uuid=' + $state.PrimaryUuid) })
$gtidRows = @($remote | Where-Object { $_ -cmatch '^loop_gtid_hex=[0-9A-F]*$' })
if ($uuidRows.Count -ne 1 -or $gtidRows.Count -ne 1) { throw 'Verified TLS connection did not identify the expected PC1 primary.' }
$protectionGuard = @'
SET @loop_protection = IF(@@GLOBAL.read_only = 1 AND @@GLOBAL.super_read_only = 1,
    'SELECT 1', 'SELECT REPLICA_WRITE_PROTECTION_CHANGED');
PREPARE loop_protection_statement FROM @loop_protection;
EXECUTE loop_protection_statement;
DEALLOCATE PREPARE loop_protection_statement;
'@
if ($Action -eq 'Start') {
    $credential = Get-ReplicaPassword
    $channelSql = @"
SET @loop_channel_sql = IF(
    (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration) = 0,
    'CHANGE REPLICATION SOURCE TO SOURCE_HOST=''192.168.3.18'', SOURCE_PORT=3306, SOURCE_USER=''loop_repl'', SOURCE_PASSWORD=''$credential'', SOURCE_AUTO_POSITION=1, SOURCE_SSL=1, SOURCE_SSL_CA=''$($state.TlsDirectory)/ca.pem'', SOURCE_SSL_CERT=''$($state.TlsDirectory)/client-cert.pem'', SOURCE_SSL_KEY=''$($state.TlsDirectory)/client-key.pem'', SOURCE_SSL_VERIFY_SERVER_CERT=1, SOURCE_TLS_VERSION=''TLSv1.2,TLSv1.3'', SOURCE_CONNECT_RETRY=5',
    'SELECT 1');
PREPARE loop_channel_setup FROM @loop_channel_sql;
EXECUTE loop_channel_setup;
DEALLOCATE PREPARE loop_channel_setup;
SET @loop_connection_guard = IF(
    (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration
     WHERE CHANNEL_NAME='' AND HOST='192.168.3.18' AND PORT=3306 AND USER='loop_repl'
       AND AUTO_POSITION=1 AND UPPER(SSL_ALLOWED)='YES' AND UPPER(SSL_VERIFY_SERVER_CERTIFICATE)='YES'
       AND SSL_CA_FILE='$($state.TlsDirectory)/ca.pem' AND SSL_CERTIFICATE='$($state.TlsDirectory)/client-cert.pem'
       AND SSL_KEY='$($state.TlsDirectory)/client-key.pem') = 1
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration) = 1,
    'SELECT 1', 'SELECT REPLICATION_CHANNEL_CHANGED');
PREPARE loop_connection_statement FROM @loop_connection_guard;
EXECUTE loop_connection_statement;
DEALLOCATE PREPARE loop_connection_statement;
START REPLICA;
SHOW REPLICA STATUS;
"@
    Save-ReplicaStage 'replication-starting'
    Invoke-ReplicaSql $state.ProductionId 'start-replication' ($identityGuard + "`n" + $protectionGuard + "`n" + $channelSql)
    Save-ReplicaStage 'replication-started'
    Write-Host 'PASS: verified TLS/GTID replication start requested. Next run Verify; receiver readiness is not confirmed yet.'
    exit 0
}

$gtidHex = $gtidRows[0].Substring('loop_gtid_hex='.Length)
$waitExpression = '0'
if ($gtidHex.Length -gt 0) { $waitExpression = 'WAIT_FOR_EXECUTED_GTID_SET(CONVERT(0x' + $gtidHex + ' USING ascii),30)' }
$readySql = @"
SET @loop_wait = $waitExpression;
SET @loop_ready = IF(@loop_wait = 0
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_status WHERE CHANNEL_NAME='' AND SERVICE_STATE='ON' AND LAST_ERROR_NUMBER=0 AND SOURCE_UUID='$($state.PrimaryUuid)') = 1
    AND (SELECT COUNT(1) FROM performance_schema.replication_applier_status WHERE CHANNEL_NAME='' AND SERVICE_STATE='ON') = 1
    AND (SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_worker) = 0
    AND (SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_coordinator) = 0,
    'SELECT 1', 'SELECT REPLICATION_NOT_CAUGHT_UP_OR_ERROR');
PREPARE loop_ready_statement FROM @loop_ready;
EXECUTE loop_ready_statement;
DEALLOCATE PREPARE loop_ready_statement;
SELECT @@GLOBAL.server_id AS server_id,@@GLOBAL.read_only AS read_only,@@GLOBAL.super_read_only AS super_read_only;
SHOW REPLICA STATUS;
"@
Invoke-ReplicaSql $state.ProductionId 'verify-replication' ($identityGuard + "`n" + $protectionGuard + "`n" + $readySql)
$null = Invoke-ReplicaDocker -Arguments @('update', '--restart=unless-stopped', $state.ProductionId)
Save-ReplicaStage 'replica-ready'
Write-Host 'PASS: PC2 receiver/applier running without worker errors, caught up to sampled PC1 GTIDs, read-only, restart policy saved.'
Write-Host 'Original PC2 container and volume remain preserved. Test application changes on PC1; all application writes must use PC1.'
