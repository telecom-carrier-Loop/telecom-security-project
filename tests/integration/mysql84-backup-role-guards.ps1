[CmdletBinding()]
param(
    [string]$ToolPath,
    [ValidateSet('', 'ReplicaProbe', 'PrimaryProbe', 'PrimaryRejected', 'BackupRejected', 'SharedLock', 'WrongContainer', 'WrongManifest', 'PrimaryBackup', 'ReplicaBackup')][string]$Case = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if (-not $ToolPath) { $ToolPath = Join-Path $PSScriptRoot '../../infrastructure/tools/mysql84-backup.ps1' }
$ToolPath = (Resolve-Path -LiteralPath $ToolPath).Path
if (-not $Case) {
    foreach ($name in @('ReplicaProbe', 'PrimaryProbe', 'PrimaryRejected', 'BackupRejected', 'SharedLock', 'WrongContainer', 'WrongManifest', 'PrimaryBackup', 'ReplicaBackup')) {
        & powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File $PSCommandPath -ToolPath $ToolPath -Case $name
        if ($LASTEXITCODE -ne 0) { throw ('Failed role guard fixture: ' + $name) }
    }
    Write-Host 'PASS: 9 mocked backup orchestration cases. No real Docker or MySQL was invoked.'
    exit 0
}

# Each child uses a disposable repository, dummy DPAPI credential and in-process Docker mock.
# SQL rejection is simulated: these tests verify failure propagation, not MySQL SQL semantics.
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('loop-backup-role-' + [guid]::NewGuid().ToString('N'))
$replicaRoot = Join-Path $fixture '.secrets/backups/mysql84/pc2'
$primaryRoot = Join-Path $fixture '.secrets/backups/mysql84/pc2-primary'
$rolePath = Join-Path $fixture '.secrets/mysql84-replication/pc2'
$null = New-Item -ItemType Directory -Path $rolePath,(Join-Path $replicaRoot 'credentials'),$primaryRoot -Force
$sourceId = 'fixture-container'
$imageId = 'sha256:fixture-image'
@{Stage='replica-ready'; ProductionId=$sourceId; ImageId=$imageId; CloneVolume='fixture-clone'; SourceVolume='fixture-original'; PrimaryUuid='98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef'} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $rolePath 'state.json') -Encoding UTF8
$source = @{Id=$sourceId; Name='/mysql-lab'; Image=$imageId; State=@{Running=$true}; Mounts=@(@{Type='volume'; Name='fixture-clone'; Destination='/var/lib/mysql'; RW=$true})}
if ($Case -eq 'WrongContainer') { $source.Name='/unrelated-database' }
$credential = [Management.Automation.PSCredential]::new('loop_backup', (ConvertTo-SecureString 'DummyFixtureOnly9!' -AsPlainText -Force))
$credential | Export-Clixml -LiteralPath (Join-Path $replicaRoot 'credentials/loop_backup.clixml')
$credential = $null
$sentinel = '{"Stage":"restore-verified","Directory":"previous-verified-backup"}'
[IO.File]::WriteAllText((Join-Path $replicaRoot 'latest.json'), $sentinel)
[IO.File]::WriteAllText((Join-Path $primaryRoot 'latest.json'), $sentinel)
$global:FixtureCopies = @{}
$global:FixtureCalls = [Collections.Generic.List[string]]::new()
$global:FixtureCleanup = $false

function global:docker {
    $a = @($args)
    $global:LASTEXITCODE = 0
    $global:FixtureCalls.Add(($a -join ' '))
    switch ($a[0]) {
        'inspect' { $source | ConvertTo-Json -Depth 6 -Compress; return }
        'ps' { $sourceId; return }
        'cp' {
            if ($a[1] -like '*:/tmp/*/preflight.txt') {
                [IO.File]::WriteAllText($a[2], "1`nloop_table=7573657273`n")
            } elseif ($a[1] -like '*:/tmp/*/snapshot.sql') {
                [IO.File]::WriteAllText($a[2], "-- Table structure for table ``users```n-- Dump completed on fixture`n")
            } elseif ($a[2] -like '*:*') {
                $global:FixtureCopies[$a[2]] = $a[1]
            } else { throw 'Unexpected fixture copy' }
            return
        }
        'exec' {
            switch ($a[2]) {
                'mkdir' { return }
                'chmod' { return }
                'stat' { '600'; return }
                'rm' { $global:FixtureCleanup=$true; return }
                'sh' {
                    $sqlPath = $global:FixtureCopies[$sourceId + ':' + $a[4]]
                    $sql = Get-Content -LiteralPath $sqlPath -Raw
                    if ($Case -in @('PrimaryRejected','BackupRejected')) {
                        if ($sql -notmatch 'BACKUP_PRIMARY_NOT_READY' -or $sql -notmatch 'read_only=0' -or $sql -notmatch 'super_read_only=0') { throw 'Missing Primary guard' }
                        $global:LASTEXITCODE=1
                        'Simulated MySQL guard rejection'
                    } elseif ($Case -in @('ReplicaProbe','ReplicaBackup')) {
                        if ($sql -notmatch 'BACKUP_REPLICA_NOT_HEALTHY' -or $sql -notmatch 'read_only=1' -or $sql -notmatch "SOURCE_UUID='98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef'") { throw 'Replica guard changed' }
                    } elseif ($Case -in @('PrimaryProbe','PrimaryBackup')) {
                        if ($sql -notmatch 'BACKUP_PRIMARY_NOT_READY' -or $sql -notmatch 'read_only=0' -or $sql -notmatch 'super_read_only=0' -or $sql -notmatch "replication_connection_status WHERE SERVICE_STATE='ON'\)=0" -or $sql -notmatch "replication_applier_status WHERE SERVICE_STATE='ON'\)=0") { throw 'Missing Primary guard' }
                    } else { throw 'Unexpected fixture SQL' }
                    return
                }
                'mysqldump' { if ($Case -notin @('PrimaryBackup','ReplicaBackup')) { throw 'Dump escaped preflight' }; return }
                default { throw ('Forbidden Docker operation in fixture: ' + $a[2]) }
            }
        }
        default { throw ('Forbidden Docker operation in fixture: ' + $a[0]) }
    }
}

$sourceRole = if ($Case -in @('ReplicaProbe','ReplicaBackup')) { 'Replica' } else { 'Primary' }
$action = if ($Case -in @('BackupRejected','PrimaryBackup','ReplicaBackup')) { 'BackupSaved' } elseif ($Case -eq 'WrongManifest') { 'RestoreTest' } else { 'PreflightSaved' }
if ($Case -eq 'WrongManifest') {
    $directory = Join-Path $primaryRoot '20261028-000000-000-abcdef'
    $null = New-Item -ItemType Directory -Path $directory
    $manifestPath = Join-Path $directory 'manifest.json'
    @{SourceRole='Replica'} | ConvertTo-Json | Set-Content -LiteralPath $manifestPath -Encoding UTF8
    @{Stage='backup-ready'; Directory=$directory; SourceId=$sourceId; ImageId=$imageId; ManifestSha256=(Get-FileHash $manifestPath).Hash} |
        ConvertTo-Json | Set-Content -LiteralPath (Join-Path $primaryRoot 'latest.json') -Encoding UTF8
}
$heldLock = $null
if ($Case -eq 'SharedLock') { $heldLock=[IO.File]::Open((Join-Path $replicaRoot 'operation.lock'),'OpenOrCreate','ReadWrite','None') }
$failure = ''
try {
    if ($Case -eq 'ReplicaBackup') { & $ToolPath -RepositoryPath $fixture -Action $action }
    else { & $ToolPath -RepositoryPath $fixture -Action $action -SourceRole $sourceRole }
}
catch { $failure=$_.Exception.Message }
finally { if ($heldLock) { $heldLock.Dispose() }; Remove-Item Function:\docker }

if ($Case -in @('ReplicaProbe','PrimaryProbe')) {
    if ($failure) { throw $failure }
    $probeRoot = if ($sourceRole -eq 'Replica') { $replicaRoot } else { $primaryRoot }
    $stateFile = @(Get-ChildItem -LiteralPath $probeRoot -Filter state.json -Recurse | Where-Object FullName -Like '*preflight-*')
    if ($stateFile.Count -ne 1 -or (Get-Content $stateFile[0].FullName -Raw | ConvertFrom-Json).Stage -ne 'preflight-passed') { throw 'No completed preflight state' }
} elseif ($Case -in @('PrimaryBackup','ReplicaBackup')) {
    if ($failure) { throw $failure }
    $backupRoot = if ($sourceRole -eq 'Replica') { $replicaRoot } else { $primaryRoot }
    $state = Get-Content -LiteralPath (Join-Path $backupRoot 'latest.json') -Raw | ConvertFrom-Json
    $manifest = Get-Content -LiteralPath (Join-Path $state.Directory 'manifest.json') -Raw | ConvertFrom-Json
    if ($state.Stage -ne 'backup-ready' -or $state.SourceRole -cne $sourceRole -or $manifest.SourceRole -cne $sourceRole) { throw 'Backup role or completion mismatch' }
} else {
    $expected = switch ($Case) {
        'PrimaryRejected' { 'Docker exec failed' }
        'BackupRejected' { 'Docker exec failed' }
        'SharedLock' { 'Another backup' }
        'WrongContainer' { 'Actual PC2 source identity changed' }
        'WrongManifest' { 'Backup source role does not match' }
    }
    if (-not $failure.Contains($expected)) { throw ('Unexpected failure: ' + $failure) }
}
$calls = $global:FixtureCalls -join "`n"
if ($calls -match '(?m)^(create |volume |stop |start )') { throw 'Restore mutation escaped barrier' }
if ($Case -notin @('PrimaryBackup','ReplicaBackup') -and $calls -match 'mysqldump') { throw 'Dump escaped preflight barrier' }
if ($Case -in @('ReplicaProbe','PrimaryProbe','PrimaryRejected','BackupRejected','PrimaryBackup','ReplicaBackup') -and -not $global:FixtureCleanup) { throw 'Private client config was not cleaned up' }
if ($Case -ne 'ReplicaBackup' -and [IO.File]::ReadAllText((Join-Path $replicaRoot 'latest.json')) -cne $sentinel) { throw 'Replica backup pointer changed' }
if ($Case -in @('ReplicaProbe','PrimaryProbe','PrimaryRejected','SharedLock','WrongContainer','ReplicaBackup') -and [IO.File]::ReadAllText((Join-Path $primaryRoot 'latest.json')) -cne $sentinel) { throw 'Primary backup pointer changed' }
if ($Case -eq 'BackupRejected') {
    $state = Get-Content -LiteralPath (Join-Path $primaryRoot 'latest.json') -Raw | ConvertFrom-Json
    if ($state.Stage -ne 'backup-failed' -or (Test-Path (Join-Path $state.Directory 'manifest.json'))) { throw 'Failed guard published a backup' }
}
Write-Host ('PASS: ' + $Case)
