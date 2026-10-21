[CmdletBinding()]
param(
    [string]$RepositoryPath,
    [ValidateSet('Prepare', 'ResumePrimary', 'Status')][string]$Action = 'Status'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) { $RepositoryPath = Join-Path $PSScriptRoot '../..' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$private = Join-Path $repo '.secrets/mysql84-replication/pc1'
$stateFile = Join-Path $private 'state.json'
$utf8 = [Text.UTF8Encoding]::new($false)

function Invoke-ExportDocker([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($Arguments -contains '-it') {
            & docker @Arguments
            $code = $LASTEXITCODE
            $lines = @()
        }
        else {
            $lines = @(& docker @Arguments 2>&1)
            $code = $LASTEXITCODE
        }
    }
    finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne 0) { throw ('Docker ' + $Arguments[0] + ' failed. Do not repeat Prepare. Keep private files; run Status.') }
    foreach ($line in $lines) { $line.ToString() }
}

function Get-ExportContainer([string]$Id) {
    $raw = @(Invoke-ExportDocker -Arguments @('inspect', $Id))
    $items = ($raw -join "`n") | ConvertFrom-Json
    if (@($items).Count -ne 1) { throw 'Expected one container.' }
    $items[0]
}

function Save-ExportStage([string]$Stage) {
    $state.Stage = $Stage
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 8), $utf8)
}

function Write-ExportText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, ($Text -replace "`r`n", "`n"), $utf8)
}

function Invoke-ExportSql([string]$Name, [string]$Sql) {
    $hostSql = Join-Path $private ($Name + '.sql')
    $containerSql = $state.TempDirectory + '/' + $Name + '.sql'
    Write-ExportText $hostSql $Sql
    $null = Invoke-ExportDocker -Arguments @('cp', $hostSql, ($state.SourceId + ':' + $containerSql))
    Write-Host ('Enter the CURRENT PC1 root password: ' + $Name)
    # SQL is read from a file; neither root nor replication passwords are CLI arguments.
    Invoke-ExportDocker -Arguments @('exec', '-it', $state.SourceId, 'sh', ($state.TempDirectory + '/root-file.sh'), $containerSql)
    $null = Invoke-ExportDocker -Arguments @('exec', $state.SourceId, 'rm', '-f', $containerSql)
}

$baseGuard = @'
SET @loop_guard = IF(
    VERSION() = '8.4.11' AND @@GLOBAL.server_id = 1
    AND @@GLOBAL.gtid_mode = 'ON' AND @@GLOBAL.enforce_gtid_consistency = 'ON'
    AND @@GLOBAL.log_bin = 1 AND @@GLOBAL.binlog_format = 'ROW'
    AND @@GLOBAL.datadir = '/var/lib/mysql/'
    AND @@GLOBAL.ssl_ca = 'ca.pem' AND @@GLOBAL.ssl_cert = 'server-cert.pem'
    AND @@GLOBAL.ssl_key = 'server-key.pem'
    AND (SELECT COUNT(1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE') = 22
    AND (SELECT COUNT(1) FROM information_schema.TABLES
         WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE' AND ENGINE <> 'InnoDB') = 0
    AND (SELECT COUNT(1) FROM performance_schema.replication_connection_configuration) = 0,
    'SELECT 1', 'SELECT PRIMARY_EXPORT_STATE_CHANGED'
);
PREPARE loop_guard_statement FROM @loop_guard;
EXECUTE loop_guard_statement;
DEALLOCATE PREPARE loop_guard_statement;
'@

if ($Action -eq 'Status') {
    if (-not (Test-Path -LiteralPath $stateFile)) { Write-Host 'No primary export has been prepared.'; exit 0 }
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Write-Host ('Stage: ' + $state.Stage)
    Write-Host ('Transfer directory: ' + $state.TransferDirectory)
    Invoke-ExportDocker -Arguments @('inspect', '--format', 'name={{.Name}} status={{.State.Status}} error={{json .State.Error}}', $state.SourceId)
    exit 0
}

$upgrade = Get-Content -LiteralPath (Join-Path $repo '.secrets/mysql80-upgrade/state.json') -Raw | ConvertFrom-Json
if ($upgrade.Stage -ne 'service-ready') { throw 'The verified PC1 upgrade must be service-ready.' }
$source = Get-ExportContainer $upgrade.ProductionId
$mounts = @($source.Mounts)
if ($source.Name -ne '/flask_mysql' -or -not $source.State.Running -or $source.Image -ne $upgrade.TargetImageId -or $mounts.Count -ne 1 -or $mounts[0].Name -ne $upgrade.CloneVolume -or $mounts[0].Destination -ne '/var/lib/mysql' -or -not $mounts[0].RW) {
    throw 'Actual PC1 container or upgraded volume changed.'
}
$users = @(Invoke-ExportDocker -Arguments @('ps', '--no-trunc', '--filter', ('volume=' + $upgrade.CloneVolume), '--format', '{{.ID}}'))
if ($users.Count -ne 1 -or $users[0] -ne $source.Id) { throw 'Unexpected shared use of the primary volume.' }

if ($Action -eq 'ResumePrimary') {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    if ($state.SourceId -ne $source.Id) { throw 'Export state does not match the actual PC1 primary.' }
    Invoke-ExportSql 'resume-primary' ($baseGuard + "`nSET GLOBAL super_read_only = OFF;`nSET GLOBAL read_only = OFF;")
    $state | Add-Member -NotePropertyName PrimaryResumed -NotePropertyValue $true -Force
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 8), $utf8)
    Write-Host 'PASS: PC1 writes resumed. Export stage is unchanged; do not repeat Prepare.'
    exit 0
}

if (Test-Path -LiteralPath $private) { throw 'Primary export files already exist. Do not repeat Prepare; run Status.' }
$tlsScript = Join-Path $PSScriptRoot 'mysql84-primary-tls.sh'
if (-not (Test-Path -LiteralPath $tlsScript)) { throw 'Place mysql84-primary-tls.sh beside this PowerShell tool.' }
$null = Invoke-ExportDocker -Arguments @('exec', $source.Id, 'openssl', 'version')
$null = New-Item -ItemType Directory -Path $private
$tag = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
$transfer = Join-Path $private 'pc2-transfer'
$null = New-Item -ItemType Directory -Path $transfer
$state = [PSCustomObject]@{
    Stage = 'preparing'; SourceId = $source.Id; SourceVolume = $upgrade.CloneVolume
    TempDirectory = ('/tmp/loop-repl-' + $tag)
    TlsDirectory = ('/var/lib/mysql/.loop-repl-' + $tag)
    TransferDirectory = $transfer; PrimaryResumed = $false
}
Save-ExportStage 'preparing'
$null = Invoke-ExportDocker -Arguments @('exec', $source.Id, 'mkdir', '-m', '700', $state.TempDirectory)
$runner = Join-Path $private 'root-file.sh'
Write-ExportText $runner "#!/bin/sh`nset -eu`nmysql --user=root --password < `"`$1`"`n"
$null = Invoke-ExportDocker -Arguments @('cp', $runner, ($source.Id + ':' + $state.TempDirectory + '/root-file.sh'))
$preflight = @'
SET @loop_account_guard = IF(
    @@GLOBAL.read_only = 0 AND @@GLOBAL.super_read_only = 0
    AND (SELECT COUNT(1) FROM mysql.user WHERE User = 'loop_repl') = 0,
    'SELECT 1', 'SELECT EXISTING_ACCOUNT_OR_WRITE_LOCK'
);
PREPARE loop_account_statement FROM @loop_account_guard;
EXECUTE loop_account_statement;
DEALLOCATE PREPARE loop_account_statement;
'@
Invoke-ExportSql 'preflight' ($baseGuard + "`n" + $preflight)
Save-ExportStage 'source-checked'

$containerTlsScript = $state.TempDirectory + '/primary-tls.sh'
$localTlsScript = Join-Path $private 'primary-tls.sh'
Write-ExportText $localTlsScript ([IO.File]::ReadAllText($tlsScript))
$null = Invoke-ExportDocker -Arguments @('cp', $localTlsScript, ($source.Id + ':' + $containerTlsScript))
$null = Invoke-ExportDocker -Arguments @('exec', $source.Id, 'sh', $containerTlsScript, 'generate', '/var/lib/mysql', $state.TlsDirectory)
Save-ExportStage 'tls-generated'
# Preserve a second copy of the previous server identity outside the data volume.
foreach ($file in @('original-server-cert.pem', 'original-server-key.pem')) {
    $null = Invoke-ExportDocker -Arguments @('cp', ($source.Id + ':' + $state.TlsDirectory + '/' + $file), (Join-Path $private $file))
}
$null = Invoke-ExportDocker -Arguments @('exec', $source.Id, 'sh', $containerTlsScript, 'install', '/var/lib/mysql', $state.TlsDirectory)
Save-ExportStage 'tls-installed'

$random = New-Object byte[] 32
$generator = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $generator.GetBytes($random) } finally { $generator.Dispose() }
$password = 'Lp9!' + [BitConverter]::ToString($random).Replace('-', '').ToLowerInvariant()
Write-ExportText (Join-Path $transfer 'replication-password') $password
$setup = @"
SET SESSION sql_log_bin = 0;
ALTER INSTANCE RELOAD TLS;
CREATE USER 'loop_repl'@'%' IDENTIFIED WITH caching_sha2_password BY '$password'
    REQUIRE SUBJECT '/CN=loop-pc2-replica';
GRANT REPLICATION SLAVE ON *.* TO 'loop_repl'@'%';
SET GLOBAL super_read_only = ON;
"@
Invoke-ExportSql 'account-and-freeze' ($baseGuard + "`n" + $preflight + "`n" + $setup)
Save-ExportStage 'primary-frozen'

$clientFile = Join-Path $private 'replica-client.cnf'
$clientConfig = @"
[client]
user=loop_repl
password=$password
host=127.0.0.1
protocol=TCP
ssl-mode=VERIFY_IDENTITY
ssl-ca=$($state.TlsDirectory)/ca.pem
ssl-cert=$($state.TlsDirectory)/client-cert.pem
ssl-key=$($state.TlsDirectory)/client-key.pem
"@
Write-ExportText $clientFile $clientConfig
$null = Invoke-ExportDocker -Arguments @('cp', $clientFile, ($source.Id + ':' + $state.TlsDirectory + '/client.cnf'))
$null = Invoke-ExportDocker -Arguments @('exec', $source.Id, 'chmod', '600', ($state.TlsDirectory + '/client.cnf'))
$tlsIdentity = @(Invoke-ExportDocker -Arguments @('exec', $source.Id, 'mysql', ('--defaults-extra-file=' + $state.TlsDirectory + '/client.cnf'), '--batch', '--skip-column-names', '--execute=SELECT VERSION(),@@GLOBAL.server_id,@@GLOBAL.server_uuid;'))
$identityRows = @($tlsIdentity | Where-Object { $_ -match '^8\.4\.11\t1\t[a-f0-9-]{36}$' })
if ($identityRows.Count -ne 1) { throw 'Verified TLS connection did not identify PC1. Primary remains write protected.' }
$primaryUuid = ($identityRows[0] -split "`t")[2]
if ($primaryUuid -eq 'f1868a2a-a5a5-11f1-8815-9693e922f083') { throw 'TLS connection identified PC2 instead of PC1.' }
Save-ExportStage 'tls-verified'

Write-Host 'Enter the SAME PC1 root password for the current GTID snapshot.'
$dump = $state.TempDirectory + '/snapshot.sql'
Invoke-ExportDocker -Arguments @('exec', '-it', $source.Id, 'mysqldump', '--user=root', '--password', '--default-character-set=utf8mb4', '--single-transaction', '--quick', '--routines', '--events', '--triggers', '--hex-blob', '--no-tablespaces', '--set-gtid-purged=ON', ('--result-file=' + $dump), '--databases', 'my_new_board_db')
$snapshot = Join-Path $transfer 'snapshot.sql'
$null = Invoke-ExportDocker -Arguments @('cp', ($source.Id + ':' + $dump), $snapshot)
$headers = @(Select-String -LiteralPath $snapshot -Pattern '^-- Table structure for table ')
if ($headers.Count -ne 22 -or (Get-Item -LiteralPath $snapshot).Length -eq 0) { throw 'Snapshot does not match 22 tables. Primary is still write protected.' }
if (@(Select-String -LiteralPath $snapshot -Pattern '^SET @@GLOBAL.GTID_PURGED=').Count -ne 1) { throw 'Snapshot GTID metadata is missing. Primary is still write protected.' }
if (@(Get-Content -LiteralPath $snapshot -Tail 5 | Select-String -Pattern '^-- Dump completed on ').Count -ne 1) { throw 'Snapshot completion marker is missing. Primary is still write protected.' }
foreach ($file in @('ca.pem', 'client-cert.pem', 'client-key.pem')) {
    $null = Invoke-ExportDocker -Arguments @('cp', ($source.Id + ':' + $state.TlsDirectory + '/' + $file), (Join-Path $transfer $file))
}
$manifest = [PSCustomObject]@{
    Format = 'loop-mysql84-seed-v1'; PrimaryAddress = '192.168.3.18'; PrimaryPort = 3306
    PrimaryUuid = $primaryUuid; PrimaryServerId = 1
    Database = 'my_new_board_db'; MySqlVersion = '8.4.11'; ExpectedTables = 22
    CreatedUtc = [DateTime]::UtcNow.ToString('o')
    Files = @(foreach ($file in @('snapshot.sql', 'ca.pem', 'client-cert.pem', 'client-key.pem', 'replication-password')) {
        $path = Join-Path $transfer $file
        [PSCustomObject]@{ Path = $file; Sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash; Length = (Get-Item -LiteralPath $path).Length }
    })
}
$manifestPath = Join-Path $transfer 'manifest.json'
Write-ExportText $manifestPath ($manifest | ConvertTo-Json -Depth 6)
Save-ExportStage 'bundle-ready'
Invoke-ExportSql 'resume-primary' ($baseGuard + "`nSET GLOBAL super_read_only = OFF;`nSET GLOBAL read_only = OFF;")
$state.PrimaryResumed = $true
Save-ExportStage 'export-ready'
Write-Host 'PASS: verified server/client certificates, dedicated replication account, current 22-table GTID snapshot. PC1 writes resumed.'
Write-Host ('Transfer only: ' + $transfer)
Write-Host ('MANIFEST_SHA256=' + (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash)
Write-Host 'Keep the manifest hash separately. Use a trusted private channel; this bundle contains app data and the replica client key/password.'
Write-Host 'Never transfer the parent directory, original server key, or CA private key. PC2 replication is not started yet.'
