[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('prepare', 'switch', 'configure')]
    [string]$Action,
    [string]$RepositoryPath,
    [string]$CandidateName = 'loop-mysql84-check-20261020-114057-962'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($RepositoryPath)) {
    $RepositoryPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '../..'
}
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$private = Join-Path $repo '.secrets/mysql84-cutover'
$stateFile = Join-Path $private 'state.json'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$database = 'my_new_board_db'

function Write-PrivateText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text.Replace("`r`n", "`n"), $utf8)
}

function Invoke-Docker([string[]]$Arguments, [switch]$AllowFailure) {
    $saved = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(& docker @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $saved }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw ('Docker command failed: ' + $Arguments[0] + '. Stop and report this action; do not publish raw SQL or logs.')
    }
    [PSCustomObject]@{ Code = $code; Lines = @($lines | ForEach-Object { [string]$_ }) }
}

function Get-Container([string]$Name) {
    $result = Invoke-Docker -Arguments @('inspect', $Name)
    $items = ($result.Lines -join "`n") | ConvertFrom-Json
    if (@($items).Count -ne 1) { throw 'Expected exactly one container.' }
    $items[0]
}

function Get-DataMount($Info) {
    $items = @($Info.Mounts | Where-Object Destination -eq '/var/lib/mysql')
    if ($items.Count -ne 1) { throw 'Cannot identify the MySQL data mount.' }
    $items[0]
}

function Save-State($State) {
    Write-PrivateText $stateFile ($State | ConvertTo-Json -Depth 6)
}

function Invoke-RootSql([string]$ContainerId, [string]$File, [switch]$AllowFailure) {
    $null = Invoke-Docker -Arguments @('cp', $File, ($ContainerId + ':/tmp/loop-cutover.sql'))
    $null = Invoke-Docker -Arguments @('exec', $ContainerId, 'chmod', '600', '/tmp/loop-cutover.sql')
    $result = Invoke-Docker -Arguments @('exec', $ContainerId, 'sh', '/tmp/mysql-run-file.sh', '/tmp/loop-cutover.sql') -AllowFailure
    $null = Invoke-Docker -Arguments @('exec', $ContainerId, 'rm', '-f', '/tmp/loop-cutover.sql')
    if ($result.Code -ne 0 -and -not $AllowFailure) { throw 'SQL failed. Stop and report the current action.' }
    $result
}

$probeSql = @'
SELECT VERSION() AS mysql_version;
SELECT IF(
    VERSION() = '8.4.11'
    AND @@GLOBAL.server_id = 1
    AND @@GLOBAL.gtid_mode = 'ON'
    AND @@GLOBAL.enforce_gtid_consistency = 'ON'
    AND @@GLOBAL.log_bin = 1
    AND @@GLOBAL.read_only = 0
    AND @@GLOBAL.super_read_only = 0
    AND @@GLOBAL.partial_revokes = 0,
    'LOOP_PRIMARY_READY', 'LOOP_PRIMARY_MISMATCH'
) AS primary_check;
'@

if ($Action -eq 'prepare') {
    $source = Get-Container 'mysql-server'
    $candidate = Get-Container $CandidateName
    $sourceData = Get-DataMount $source
    $candidateData = Get-DataMount $candidate
    if (-not $source.State.Running -or -not $candidate.State.Running) { throw 'Both existing containers must be running for prepare.' }
    if ($source.Id -eq $candidate.Id -or $sourceData.Source -eq $candidateData.Source) { throw 'Source and candidate must use different data volumes.' }
    if ($candidateData.Type -ne 'volume' -or -not $candidateData.RW) { throw 'Candidate needs its own writable named data volume.' }
    if ($candidate.HostConfig.NetworkMode -ne 'none') { throw 'Candidate must still have network=none.' }
    $rootMount = @($candidate.Mounts | Where-Object Destination -eq '/run/secrets/root-password')
    if ($rootMount.Count -ne 1 -or $rootMount[0].RW) { throw 'Candidate root-password must be mounted read-only.' }
    $null = New-Item -ItemType Directory -Path $private -Force

    if (Test-Path -LiteralPath $stateFile) {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($state.Stage -ne 'prepared' -or $state.SourceId -ne $source.Id -or $state.CandidateId -ne $candidate.Id) {
            throw 'An existing cutover state cannot be overwritten. Stop and report its stage.'
        }
    }
    else {
        $state = [PSCustomObject]@{
            Stage = 'prepared'; SourceId = $source.Id; CandidateId = $candidate.Id
            RollbackName = ('mysql-server-26-rollback-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
            SourceRestartPolicy = $source.HostConfig.RestartPolicy
            SourceData = $sourceData.Source; DataVolume = $candidateData.Name
            CandidateData = $candidateData.Source; ImageId = $candidate.Image
            ServerArguments = @($candidate.Config.Cmd); NewId = ''; Configured = $false
        }
    }

    $runner = Join-Path $private 'mysql-run-file.sh'
    $rootPassword = Join-Path $private 'root-password'
    $null = Invoke-Docker -Arguments @('cp', ($candidate.Id + ':/tmp/mysql-run-file.sh'), $runner)
    $null = Invoke-Docker -Arguments @('cp', ($candidate.Id + ':/run/secrets/root-password'), $rootPassword)
    $probe = Join-Path $private 'primary-check.sql'
    Write-PrivateText $probe $probeSql
    $result = Invoke-RootSql $candidate.Id $probe
    if ($result.Lines -notcontains 'LOOP_PRIMARY_READY') { throw 'Candidate version or settings do not match.' }

    $passwordFile = Join-Path $private 'app-password'
    if (-not (Test-Path -LiteralPath $passwordFile)) {
        $bytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        Write-PrivateText $passwordFile ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant())
    }
    $password = [IO.File]::ReadAllText($passwordFile).Trim()
    if ($password -notmatch '^[0-9a-f]{64}$') { throw 'Existing app-password has an unexpected format.' }
    $accountSql = @'
CREATE USER IF NOT EXISTS 'loop_app'@'%' IDENTIFIED BY '__PASSWORD__';
ALTER USER 'loop_app'@'%' IDENTIFIED BY '__PASSWORD__';
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE
ON `my\_new\_board\_db`.* TO 'loop_app'@'%';
SELECT 'LOOP_APP_ACCOUNT_READY' AS account_check;
'@
    $accountFile = Join-Path $private 'create-app-account.sql'
    Write-PrivateText $accountFile ($accountSql.Replace('__PASSWORD__', $password))
    try {
        $result = Invoke-RootSql $candidate.Id $accountFile
        if ($result.Lines -notcontains 'LOOP_APP_ACCOUNT_READY') { throw 'App account setup did not complete.' }
    }
    finally { Remove-Item -LiteralPath $accountFile -Force -ErrorAction SilentlyContinue }
    Save-State $state
    Write-Host 'PASS: prepare. App account and private cutover files are ready. Flask must remain stopped.'
    exit 0
}

if (-not (Test-Path -LiteralPath $stateFile)) { throw 'Run prepare first.' }
$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json

if ($Action -eq 'switch') {
    if ($state.Stage -ne 'prepared') { throw ('Do not repeat switch. Current stage: ' + $state.Stage) }
    $source = Get-Container 'mysql-server'
    $candidate = Get-Container $state.CandidateId
    if ($source.Id -ne $state.SourceId) { throw 'Original mysql-server identity changed.' }
    $sourceData = Get-DataMount $source
    $candidateData = Get-DataMount $candidate
    if ($sourceData.Source -ne $state.SourceData -or $candidateData.Source -ne $state.CandidateData) { throw 'Data mounts changed after prepare.' }
    if ($candidate.HostConfig.NetworkMode -ne 'none') { throw 'Candidate is no longer isolated.' }
    $probe = Join-Path $private 'primary-check.sql'
    $result = Invoke-RootSql $candidate.Id $probe
    if ($result.Lines -notcontains 'LOOP_PRIMARY_READY') { throw 'Candidate is not ready.' }

    # No two mysqld processes may open the same data volume.
    $null = Invoke-Docker -Arguments @('update', '--restart=no', $candidate.Id)
    $null = Invoke-Docker -Arguments @('stop', '--time', '60', $candidate.Id)
    $stopped = Get-Container $candidate.Id
    if ($stopped.State.Running -or $stopped.State.ExitCode -ne 0) { throw 'Candidate did not shut down cleanly. Original is still preserved.' }
    $state.Stage = 'candidate-stopped'; Save-State $state

    $null = Invoke-Docker -Arguments @('update', '--restart=no', $source.Id)
    $null = Invoke-Docker -Arguments @('stop', '--time', '60', $source.Id)
    $stopped = Get-Container $source.Id
    if ($stopped.State.Running -or $stopped.State.ExitCode -ne 0) { throw 'Original did not shut down cleanly. Stop and report the stage.' }
    $null = Invoke-Docker -Arguments @('rename', $source.Id, $state.RollbackName)
    $state.Stage = 'source-renamed'; Save-State $state

    $rootPassword = Join-Path $private 'root-password'
    $createArgs = @(
        'create', '--name', 'mysql-server', '--restart=no', '--network', 'bridge', '--memory', '2g',
        '--publish', '127.0.0.1:3306:3306', '--label', 'com.loop.role=mysql-primary',
        '--env', 'MYSQL_ROOT_PASSWORD_FILE=/run/secrets/root-password', '--env', 'MYSQL_ROOT_HOST=localhost',
        '--mount', ('type=volume,source=' + $state.DataVolume + ',target=/var/lib/mysql'),
        '--mount', ('type=bind,source=' + $rootPassword + ',target=/run/secrets/root-password,readonly'),
        $state.ImageId
    ) + @($state.ServerArguments)
    $created = Invoke-Docker -Arguments $createArgs
    $state.NewId = ($created.Lines -join '').Trim()
    $state.Stage = 'created'; Save-State $state

    # Check inherited data and the new private secret before starting mysqld.
    $production = Get-Container $state.NewId
    $productionData = Get-DataMount $production
    $secret = @($production.Mounts | Where-Object Destination -eq '/run/secrets/root-password')
    if ($productionData.Name -ne $state.DataVolume -or $productionData.Source -ne $state.CandidateData -or -not $productionData.RW) { throw 'Production data mount mismatch. New server was not started.' }
    if ($productionData.Source -eq $state.SourceData -or $secret.Count -ne 1 -or $secret[0].RW) { throw 'Production mount safety check failed. New server was not started.' }
    $null = Invoke-Docker -Arguments @('cp', (Join-Path $private 'mysql-run-file.sh'), ($state.NewId + ':/tmp/mysql-run-file.sh'))
    $null = Invoke-Docker -Arguments @('start', $state.NewId)
    $state.Stage = 'started'; Save-State $state

    $ready = $false
    foreach ($attempt in 1..30) {
        $result = Invoke-RootSql $state.NewId $probe -AllowFailure
        if ($result.Code -eq 0 -and $result.Lines -contains 'LOOP_PRIMARY_READY') { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) { throw 'New MySQL is not ready. Leave Flask stopped and report the stage.' }
    $client = [Net.Sockets.TcpClient]::new()
    try { $client.Connect('127.0.0.1', 3306) } finally { $client.Dispose() }
    $null = Invoke-Docker -Arguments @('update', '--restart=unless-stopped', $state.NewId)
    $state.Stage = 'switched'; Save-State $state
    $null = Invoke-Docker -Arguments @('rm', $state.CandidateId)
    Write-Host 'PASS: switch. MySQL 8.4.11 is available at 127.0.0.1:3306.'
    Write-Host ('Original preserved as: ' + $state.RollbackName)
    Write-Host 'Next: configure. PC2 replication is not connected yet.'
    exit 0
}

if ($state.Stage -ne 'switched') { throw 'Switch must complete before configure.' }
$production = Get-Container 'mysql-server'
if ($production.Id -ne $state.NewId -or -not $production.State.Running) { throw 'Production identity or running state does not match.' }
$password = [IO.File]::ReadAllText((Join-Path $private 'app-password')).Trim()
if ($password -notmatch '^[0-9a-f]{64}$') { throw 'Invalid private app-password.' }
$settings = [ordered]@{ DB_HOST = '127.0.0.1'; DB_PORT = '3306'; DB_NAME = $database; DB_USER = 'loop_app'; DB_PASSWORD = $password }
$envFiles = @((Join-Path $repo '.env'), (Join-Path $repo 'backend/.env'))
$existing = @($envFiles | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
if ($existing.Count -eq 0) { $existing = @((Join-Path $repo 'backend/.env')) }
foreach ($envFile in $existing) {
    $text = ''
    if (Test-Path -LiteralPath $envFile) {
        $backupName = if ($envFile -eq $envFiles[0]) { 'repo-env.before' } else { 'backend-env.before' }
        $backup = Join-Path $private $backupName
        if (-not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $envFile -Destination $backup }
        $text = [IO.File]::ReadAllText($envFile).Replace("`r`n", "`n")
    }
    foreach ($key in $settings.Keys) {
        $pattern = '(?m)^\s*(?:export\s+)?' + [regex]::Escape($key) + '\s*=.*$'
        $line = $key + '=' + $settings[$key]
        if ([regex]::IsMatch($text, $pattern)) { $text = [regex]::Replace($text, $pattern, $line) }
        else { $text = $text.TrimEnd() + "`n" + $line + "`n" }
    }
    Write-PrivateText $envFile $text
}
$state.Configured = $true; Save-State $state
Write-Host 'PASS: configure. Existing local .env files were backed up and their five DB settings updated.'
Write-Host 'Restart Flask on port 5000 after clearing old DB process environment variables. React stays on 5173.'
