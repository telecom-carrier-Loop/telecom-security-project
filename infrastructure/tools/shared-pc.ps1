[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('prepare-primary', 'prepare-replica', 'up', 'bootstrap-primary', 'connect-replica', 'status', 'write-probe', 'verify', 'stop')]
    [string]$Action,
    [Parameter(Mandatory = $true)][ValidateSet('pc1', 'pc2')][string]$Role,
    [string]$TransferDirectory,
    [string]$ProbeId,
    [string]$EnvironmentFile,
    [string]$SecretDirectory,
    [string]$ProjectName,
    [string]$ComposeOverride
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$ComposeDirectory = Join-Path $RepoRoot 'infrastructure/docker/compose/shared-pc'
$MysqlImage = 'mysql:8.4@sha256:24989179f58856db763f418010c1169fecc944e3ec1ea7e921572d83eb070f70'
$Utf8 = New-Object System.Text.UTF8Encoding($false)
if (-not $EnvironmentFile) { $EnvironmentFile = Join-Path $RepoRoot '.env.shared-pc' }
if (-not $SecretDirectory) { $SecretDirectory = Join-Path $RepoRoot '.secrets/shared-pc' }
if (-not $ProjectName) { $ProjectName = "telecom-$Role" }
$SecretDirectory = [IO.Path]::GetFullPath($SecretDirectory)
$SecretsBoundary = [IO.Path]::GetFullPath((Join-Path $RepoRoot '.secrets')) + [IO.Path]::DirectorySeparatorChar
if (-not $SecretDirectory.StartsWith($SecretsBoundary, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'SecretDirectory must stay inside this repository .secrets directory.'
}
if ($ProjectName -notmatch '^telecom-(pc[12]|infra-test-[a-z0-9-]+)$') { throw 'Unexpected project name.' }
$NodeDirectory = Join-Path $SecretDirectory $Role

function Write-NewText([string]$Path, [string]$Text) {
    if (Test-Path -LiteralPath $Path) { throw "Existing file preserved: $Path" }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, $Utf8)
}
function New-Password([string]$Path, [int]$ByteCount = 24) {
    $bytes = New-Object byte[] $ByteCount
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    Write-NewText $Path ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
}
function Invoke-Docker([string[]]$DockerArgs) {
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& docker @DockerArgs 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($code -ne 0) {
        # These calls contain paths/settings only, never SQL/password arguments.
        $message = ($lines | ForEach-Object { $_.ToString() }) -join "`n"
        throw "Docker operation failed ($code): $message"
    }
    return (($lines | ForEach-Object { $_.ToString() }) -join "`n")
}
function Get-ComposeArguments {
    $result = @('compose', '--env-file', $EnvironmentFile, '-p', $ProjectName,
                '-f', (Join-Path $ComposeDirectory "$Role.yaml"))
    if ($ComposeOverride) { $result += @('-f', $ComposeOverride) }
    return $result
}
function Invoke-Compose([string[]]$CommandArgs) {
    Invoke-Docker ((Get-ComposeArguments) + $CommandArgs)
}
function Invoke-Db([string]$Query, [switch]$ExpectReadOnly) {
    $command = 'MYSQL_PWD="$(cat /run/secrets/root-password)" exec mysql --protocol=socket -uroot --batch --skip-column-names'
    $arguments = (Get-ComposeArguments) + @('exec', '-T', 'mysql', 'sh', '-c', $command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $OutputEncoding = $Utf8
    try {
        $lines = @($Query | & docker @arguments 2>&1)
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    $text = ($lines | ForEach-Object { $_.ToString() }) -join "`n"
    if ($ExpectReadOnly) {
        if ($code -eq 0 -or $text -notmatch 'ERROR 1290') { throw 'Replica write was not rejected with ERROR 1290.' }
        return 'rejected'
    }
    if ($code -ne 0) {
        # Full SQL errors can contain password hashes; report error numbers only.
        $numbers = [regex]::Matches($text, 'ERROR [0-9]+') | ForEach-Object { $_.Value }
        throw "MySQL operation failed ($code): $($numbers -join ', '). Raw output suppressed."
    }
    return $text.Trim()
}
function Wait-Database {
    for ($attempt = 0; $attempt -lt 60; $attempt++) {
        try { if ((Invoke-Db 'SELECT 1;') -eq '1') { return } } catch { }
        Start-Sleep -Seconds 2
    }
    throw 'MySQL is not ready. Inspect this project container locally; do not publish raw logs.'
}
function Read-ReplicationPassword {
    $value = [IO.File]::ReadAllText((Join-Path $NodeDirectory 'replication-password')).Trim()
    if ($value -notmatch '^[a-f0-9]{32}$') { throw 'Invalid local replication credential format.' }
    return $value
}
function Show-CaFingerprint {
    $path = Join-Path $NodeDirectory 'tls/ca.crt'
    Write-Host "CA_FILE_SHA256=$((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash)"
}
function Prepare-Primary {
    if ($Role -ne 'pc1') { throw 'prepare-primary requires pc1.' }
    if (Test-Path -LiteralPath (Join-Path $NodeDirectory 'prepared')) {
        Write-Host 'Existing primary material preserved.'
        Show-CaFingerprint
        return
    }
    if (Test-Path -LiteralPath $SecretDirectory) { throw 'Partial/existing material found. Inspect it; nothing overwritten.' }
    [IO.Directory]::CreateDirectory($SecretDirectory) | Out-Null
    $script = Join-Path $ComposeDirectory 'generate-tls.sh'
    Invoke-Docker -DockerArgs @('run', '--rm', '--entrypoint', 'bash', '--mount', "type=bind,src=$SecretDirectory,dst=/material",
        '--mount', "type=bind,src=$script,dst=/generate-tls.sh,readonly", $MysqlImage, '/generate-tls.sh') | Out-Null
    New-Password (Join-Path $NodeDirectory 'root-password')
    New-Password (Join-Path $NodeDirectory 'replication-password') 16
    Copy-Item -LiteralPath (Join-Path $NodeDirectory 'replication-password') -Destination (Join-Path $SecretDirectory 'pc2-transfer/replication-password')
    Write-NewText (Join-Path $NodeDirectory 'prepared') 'pc1'
    Show-CaFingerprint
    Write-Host "Transfer only $SecretDirectory\pc2-transfer to PC2 through a trusted private channel. Never transfer pki/ca.key or pc1/root-password."
}
function Prepare-Replica {
    if ($Role -ne 'pc2') { throw 'prepare-replica requires pc2.' }
    if (Test-Path -LiteralPath (Join-Path $NodeDirectory 'prepared')) {
        Write-Host 'Existing replica material preserved.'
        Show-CaFingerprint
        return
    }
    if (-not $TransferDirectory) { throw 'Supply the privately copied pc2-transfer directory.' }
    if (Test-Path -LiteralPath $NodeDirectory) { throw 'Partial/existing replica material found. Nothing overwritten.' }
    $files = @('replication-password', 'tls/ca.crt', 'tls/server.crt', 'tls/server.key', 'tls/client.crt', 'tls/client.key')
    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath (Join-Path $TransferDirectory $file) -PathType Leaf)) { throw "Missing transfer file: $file" }
    }
    foreach ($file in $files) {
        $destination = Join-Path $NodeDirectory $file
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $TransferDirectory $file) -Destination $destination
    }
    New-Password (Join-Path $NodeDirectory 'root-password')
    Write-NewText (Join-Path $NodeDirectory 'prepared') 'pc2'
    Show-CaFingerprint
    Write-Host 'Compare the CA file fingerprint with PC1 before starting this replica.'
}
function Bootstrap-Primary {
    if ($Role -ne 'pc1') { throw 'bootstrap-primary requires pc1.' }
    Wait-Database
    if ((Invoke-Db 'SELECT @@server_id,@@gtid_mode,@@read_only,@@super_read_only;') -ne "1`tON`t0`t0") {
        throw 'Primary identity/state mismatch; refusing bootstrap.'
    }
    $marker = Join-Path $NodeDirectory 'bootstrap-complete'
    if (Test-Path -LiteralPath $marker) { Write-Host 'Existing primary bootstrap preserved.'; return }
    $count = Invoke-Db "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema');"
    if ($count -ne '0') { throw 'Initial bootstrap requires empty project databases. No reset/drop performed.' }
    if ((Invoke-Db "SELECT COUNT(*) FROM mysql.user WHERE User='telecom_repl';") -ne '0') {
        throw 'Existing replication account found; inspect earlier setup instead of replacing credentials.'
    }
    $password = Read-ReplicationPassword
    Invoke-Db @"
CREATE USER 'telecom_repl'@'%' IDENTIFIED BY '$password'
  REQUIRE SUBJECT '/CN=telecom-pc2-replica' AND ISSUER '/CN=Telecom Shared PC CA';
GRANT REPLICATION SLAVE ON *.* TO 'telecom_repl'@'%';
CREATE DATABASE telecom_infra_check CHARACTER SET utf8mb4;
CREATE TABLE telecom_infra_check.replication_probe (id CHAR(36) PRIMARY KEY, payload VARCHAR(64) NOT NULL) ENGINE=InnoDB;
"@ | Out-Null
    Write-NewText $marker 'primary bootstrap completed'
    Write-Host 'Primary bootstrap complete; app schema/migrations were not changed.'
}
function Wait-Replication {
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $receiver = Invoke-Db 'SELECT SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status;'
        $applier = Invoke-Db 'SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;'
        $errors = Invoke-Db 'SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_worker;'
        if ($receiver -eq "ON`t0" -and $applier -eq 'ON' -and $errors -eq '0') { return }
        Start-Sleep -Seconds 2
    }
    throw 'Replication is not running cleanly. Run status; report error numbers only.'
}
function Connect-Replica {
    if ($Role -ne 'pc2') { throw 'connect-replica requires pc2.' }
    Wait-Database
    if ((Invoke-Db 'SELECT @@server_id,@@gtid_mode;') -ne "2`tON") { throw 'Replica identity mismatch.' }
    $channels = Invoke-Db 'SELECT COUNT(*) FROM performance_schema.replication_connection_configuration;'
    if ($channels -ne '0') {
        $configuration = Invoke-Db 'SELECT HOST,PORT,AUTO_POSITION,SSL_ALLOWED,SSL_VERIFY_SERVER_CERTIFICATE FROM performance_schema.replication_connection_configuration;'
        if ($configuration -ne "mysql-primary.telecom.test`t$PrimaryPort`t1`tYES`tYES") {
            throw 'Existing channel differs; no reset/reconfiguration performed.'
        }
        if ((Invoke-Db 'SELECT @@read_only,@@super_read_only;') -ne "1`t1") { throw 'Existing replica protection changed; refusing automatic changes.' }
        Invoke-Db 'START REPLICA;' | Out-Null
    } else {
        $count = Invoke-Db "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema NOT IN ('mysql','sys','performance_schema','information_schema');"
        if ($count -ne '0') { throw 'Replica must be empty before first connection. No data removed.' }
        $password = Read-ReplicationPassword
        Invoke-Db @"
SET PERSIST read_only=ON;
SET PERSIST super_read_only=ON;
CHANGE REPLICATION SOURCE TO SOURCE_HOST='mysql-primary.telecom.test', SOURCE_PORT=$PrimaryPort,
  SOURCE_USER='telecom_repl', SOURCE_PASSWORD='$password', SOURCE_AUTO_POSITION=1,
  SOURCE_SSL=1, SOURCE_SSL_CA='/run/mysql-tls/ca.crt',
  SOURCE_SSL_CERT='/run/mysql-tls/client.crt', SOURCE_SSL_KEY='/run/mysql-tls/client.key',
  SOURCE_SSL_VERIFY_SERVER_CERT=1, SOURCE_TLS_VERSION='TLSv1.2,TLSv1.3',
  SOURCE_CONNECT_RETRY=5, SOURCE_RETRY_COUNT=12;
START REPLICA;
"@ | Out-Null
    }
    Wait-Replication
    Write-Host 'PASS: GTID receiver/applier running with verified server TLS and dedicated client certificate.'
}
function Show-Status {
    Write-Host "server_id / GTID / read_only / super_read_only: $(Invoke-Db 'SELECT @@server_id,@@gtid_mode,@@read_only,@@super_read_only;')"
    if ($Role -eq 'pc2') {
        Write-Host "receiver / error: $(Invoke-Db 'SELECT SERVICE_STATE,LAST_ERROR_NUMBER FROM performance_schema.replication_connection_status;')"
        Write-Host "applier: $(Invoke-Db 'SELECT SERVICE_STATE FROM performance_schema.replication_applier_status;')"
        Write-Host "max worker error: $(Invoke-Db 'SELECT COALESCE(MAX(LAST_ERROR_NUMBER),0) FROM performance_schema.replication_applier_status_by_worker;')"
        Write-Host "host / port / GTID / TLS / identity verification: $(Invoke-Db 'SELECT HOST,PORT,AUTO_POSITION,SSL_ALLOWED,SSL_VERIFY_SERVER_CERTIFICATE FROM performance_schema.replication_connection_configuration;')"
    }
}
function Verify-Probe {
    if ($Role -ne 'pc2') { throw 'verify requires pc2.' }
    $guid = [guid]::Empty
    if (-not [guid]::TryParse($ProbeId, [ref]$guid)) { throw 'Supply the PROBE_ID printed on PC1.' }
    Wait-Database
    Wait-Replication
    $configuration = Invoke-Db 'SELECT SSL_ALLOWED,SSL_VERIFY_SERVER_CERTIFICATE FROM performance_schema.replication_connection_configuration;'
    if ($configuration -ne "YES`tYES") { throw 'Verified TLS is not enabled.' }
    $found = $false
    for ($attempt = 0; $attempt -lt 30; $attempt++) {
        $count = Invoke-Db "SELECT COUNT(*) FROM telecom_infra_check.replication_probe WHERE id='$guid' AND payload='shared-pc-synthetic';"
        if ($count -eq '1') { $found = $true; break }
        Start-Sleep -Seconds 1
    }
    if (-not $found) { throw 'Source probe was not replicated in time.' }
    if ((Invoke-Db 'SELECT @@read_only,@@super_read_only;') -ne "1`t1") { throw 'Replica is not read-only.' }
    $newId = [guid]::NewGuid().ToString()
    Invoke-Db "INSERT INTO telecom_infra_check.replication_probe VALUES ('$newId','must-fail');" -ExpectReadOnly | Out-Null
    Write-Host "PASS: probe=$guid replicated; GTID/TLS identity enabled; replica root write rejected (1290)."
}

$previousSecretRoot = $env:SHARED_SECRET_ROOT
try {
    $env:SHARED_SECRET_ROOT = $SecretDirectory.Replace('\', '/')
    if (-not (Test-Path -LiteralPath $EnvironmentFile)) {
        if ($Action -notin @('prepare-primary', 'prepare-replica')) { throw 'Prepare the local files first.' }
        Copy-Item -LiteralPath (Join-Path $ComposeDirectory '.env.example') -Destination $EnvironmentFile
    }
    $settings = @{}
    foreach ($line in [IO.File]::ReadAllLines($EnvironmentFile)) {
        if ($line -match '^([A-Z_]+)=([^#\s]+)\s*$') { $settings[$matches[1]] = $matches[2] }
    }
    foreach ($name in @('PRIMARY_IP', 'REPLICA_IP')) {
        $address = $null
        if (-not $settings.ContainsKey($name) -or -not [Net.IPAddress]::TryParse($settings[$name], [ref]$address) -or $address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
            throw "Set a valid IPv4 $name in the environment file."
        }
    }
    $PrimaryPort = 3306
    if ($settings.ContainsKey('PRIMARY_PORT')) { $PrimaryPort = [int]$settings['PRIMARY_PORT'] }
    if ($PrimaryPort -lt 1 -or $PrimaryPort -gt 65535) { throw 'Invalid PRIMARY_PORT.' }
    switch ($Action) {
        'prepare-primary' { Prepare-Primary }
        'prepare-replica' { Prepare-Replica }
        'up' {
            if (-not (Test-Path -LiteralPath (Join-Path $NodeDirectory 'prepared'))) { throw 'Prepare this role first.' }
            Invoke-Compose -CommandArgs @('config', '--quiet') | Out-Null
            Invoke-Compose -CommandArgs @('up', '--build', '-d', '--wait', '--wait-timeout', '180') | Out-Null
            Wait-Database
            if ($Role -eq 'pc2') {
                $channels = Invoke-Db 'SELECT COUNT(*) FROM performance_schema.replication_connection_configuration;'
                if ($channels -eq '0') {
                    Invoke-Db 'SET PERSIST read_only=ON; SET PERSIST super_read_only=ON;' | Out-Null
                } elseif ((Invoke-Db 'SELECT @@read_only,@@super_read_only;') -ne "1`t1") {
                    throw 'Existing replica protection changed; inspect possible manual promotion. No flags changed.'
                }
            }
            Write-Host "PASS: $ProjectName MySQL ready."
        }
        'bootstrap-primary' { Bootstrap-Primary }
        'connect-replica' { Connect-Replica }
        'status' { Show-Status }
        'write-probe' {
            if ($Role -ne 'pc1') { throw 'write-probe requires pc1.' }
            if ((Invoke-Db 'SELECT @@server_id,@@read_only,@@super_read_only;') -ne "1`t0`t0") { throw 'Primary state mismatch.' }
            $id = [guid]::NewGuid().ToString()
            Invoke-Db "INSERT INTO telecom_infra_check.replication_probe VALUES ('$id','shared-pc-synthetic');" | Out-Null
            Write-Host "PROBE_ID=$id"
        }
        'verify' { Verify-Probe }
        'stop' { Invoke-Compose -CommandArgs @('stop') | Out-Null; Write-Host 'Stopped; volumes, credentials and certificates preserved.' }
    }
} finally { $env:SHARED_SECRET_ROOT = $previousSecretRoot }
