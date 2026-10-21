[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../mysql84-primary-export.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-primary-export-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$utf8 = [Text.UTF8Encoding]::new($false)

function Assert-ExportTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function New-ExportCase([string]$Name) {
    $path = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $path '.secrets/mysql80-upgrade') -Force
    $upgrade = @{ Stage = 'service-ready'; ProductionId = 'source-id'; TargetImageId = 'image84'; CloneVolume = 'pc1-upgraded-data' }
    [IO.File]::WriteAllText((Join-Path $path '.secrets/mysql80-upgrade/state.json'), ($upgrade | ConvertTo-Json), $utf8)
    $source = [PSCustomObject]@{
        Id = 'source-id'; Name = '/flask_mysql'; Image = 'image84'
        State = [PSCustomObject]@{ Running = $true }
        Mounts = @([PSCustomObject]@{ Name = 'pc1-upgraded-data'; Destination = '/var/lib/mysql'; RW = $true })
    }
    $global:ExportMock = @{
        Source = $source; Calls = [Collections.Generic.List[object]]::new(); Sql = [Collections.Generic.List[string]]::new()
        Files = @{}; SharedVolume = $false; GuardFailure = $false; TlsFailure = $false
        DumpFailure = $false; MissingGtid = $false; IncompleteDump = $false; TableCount = 22; Frozen = $false; BenignStderr = $false
    }
    $path
}

function global:docker {
    $command = @($args)
    $global:LASTEXITCODE = 0
    $global:ExportMock.Calls.Add($command)
    switch ($command[0]) {
        'inspect' {
            if ($command -contains '--format') { 'mock primary status'; return }
            ConvertTo-Json -InputObject @($global:ExportMock.Source) -Depth 8 -Compress
            return
        }
        'ps' {
            'source-id'
            if ($global:ExportMock.SharedVolume) { 'other-writer' }
            return
        }
        'cp' {
            if ($command[1] -like 'source-id:*') {
                $text = 'mock certificate or key'
                if ($command[1] -like '*/snapshot.sql') {
                    $lines = @(1..$global:ExportMock.TableCount | ForEach-Object { '-- Table structure for table t' + $_ })
                    if (-not $global:ExportMock.MissingGtid) { $lines += "SET @@GLOBAL.GTID_PURGED=/*!80000 '+'*/ '';" }
                    if (-not $global:ExportMock.IncompleteDump) { $lines += '-- Dump completed on mock-time' }
                    $text = $lines -join "`n"
                }
                [IO.File]::WriteAllText($command[2], $text, [Text.UTF8Encoding]::new($false))
            }
            else { $global:ExportMock.Files[$command[2]] = [IO.File]::ReadAllText($command[1]) }
            return
        }
        'exec' {
            if ($global:ExportMock.BenignStderr -and -not ($command -contains '-it')) { Write-Error 'mock benign native progress' }
            if ($command -contains 'mysqldump') {
                if ($global:ExportMock.DumpFailure) { $global:LASTEXITCODE = 1 }
                return
            }
            if ($command -contains '-it') {
                $sql = $global:ExportMock.Files['source-id:' + $command[-1]]
                $global:ExportMock.Sql.Add($sql)
                if ($global:ExportMock.GuardFailure) { $global:LASTEXITCODE = 1; return }
                if ($sql.Contains('SET GLOBAL super_read_only = ON;')) { $global:ExportMock.Frozen = $true }
                if ($sql.Contains('SET GLOBAL super_read_only = OFF;')) { $global:ExportMock.Frozen = $false }
                return
            }
            if ($command -contains 'mysql') {
                if ($global:ExportMock.TlsFailure) { $global:LASTEXITCODE = 1; return }
                "8.4.11`t1`t98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef"
            }
            return
        }
        default { throw ('Unexpected mock Docker command: ' + $command[0]) }
    }
}

function Invoke-ExportFailure([string]$Path, [string]$Message) {
    $caught = ''
    try { & $tool -RepositoryPath $Path -Action Prepare }
    catch { $caught = $_.Exception.Message }
    Assert-ExportTest ($caught -like ('*' + $Message + '*')) ('Expected ' + $Message + '; got ' + $caught)
}

try {
    $casePath = New-ExportCase 'wrong-volume'
    $global:ExportMock.Source.Mounts[0].Name = 'original-80-volume'
    Invoke-ExportFailure $casePath 'upgraded volume changed'
    Assert-ExportTest (@($global:ExportMock.Calls | Where-Object { $_[0] -eq 'exec' }).Count -eq 0) 'Wrong source was mutated.'
    Write-Host 'PASS: wrong primary volume rejected before exec'

    $casePath = New-ExportCase 'shared-volume'
    $global:ExportMock.SharedVolume = $true
    Invoke-ExportFailure $casePath 'Unexpected shared use'
    Assert-ExportTest ($global:ExportMock.Sql.Count -eq 0) 'Shared source received SQL.'
    Write-Host 'PASS: shared primary volume rejected'

    $casePath = New-ExportCase 'sql-guard-failure'
    $global:ExportMock.GuardFailure = $true
    Invoke-ExportFailure $casePath 'Docker exec failed'
    Assert-ExportTest (-not $global:ExportMock.Frozen) 'Failed preflight locked primary.'
    Assert-ExportTest (@($global:ExportMock.Calls | Where-Object { $_ -contains 'generate' }).Count -eq 0) 'TLS generated before SQL preflight.'
    Write-Host 'PASS: failed SQL preflight prevents TLS/account changes'

    $casePath = New-ExportCase 'tls-failure'
    $global:ExportMock.TlsFailure = $true
    Invoke-ExportFailure $casePath 'Docker exec failed'
    Assert-ExportTest (@($global:ExportMock.Calls | Where-Object { $_ -contains 'mysqldump' }).Count -eq 0) 'Snapshot attempted after TLS failure.'
    Write-Host 'PASS: verified client TLS failure prevents snapshot'

    foreach ($failure in @('DumpFailure', 'MissingGtid', 'IncompleteDump', 'TableCount')) {
        $casePath = New-ExportCase $failure
        $message = 'Docker exec failed'
        if ($failure -eq 'TableCount') { $global:ExportMock.TableCount = 7; $message = 'does not match 22' }
        elseif ($failure -eq 'MissingGtid') { $global:ExportMock.MissingGtid = $true; $message = 'GTID metadata is missing' }
        elseif ($failure -eq 'IncompleteDump') { $global:ExportMock.IncompleteDump = $true; $message = 'completion marker is missing' }
        else { $global:ExportMock.DumpFailure = $true }
        Invoke-ExportFailure $casePath $message
        Assert-ExportTest $global:ExportMock.Frozen 'Failed snapshot unexpectedly released primary write lock.'
        Assert-ExportTest (-not (Test-Path -LiteralPath (Join-Path $casePath '.secrets/mysql84-replication/pc1/pc2-transfer/manifest.json'))) 'Failed snapshot was marked ready.'
        if ($failure -eq 'TableCount') {
            & $tool -RepositoryPath $casePath -Action ResumePrimary
            Assert-ExportTest (-not $global:ExportMock.Frozen) 'Explicit resume did not release write lock.'
            $state = Get-Content -LiteralPath (Join-Path $casePath '.secrets/mysql84-replication/pc1/state.json') -Raw | ConvertFrom-Json
            Assert-ExportTest ($state.Stage -ne 'export-ready') 'Resume incorrectly marked incomplete export ready.'
        }
        Write-Host ('PASS: ' + $failure + ' is blocked; incomplete snapshot is not published')
    }

    $casePath = New-ExportCase 'success'
    $global:ExportMock.BenignStderr = $true
    & $tool -RepositoryPath $casePath -Action Prepare
    $private = Join-Path $casePath '.secrets/mysql84-replication/pc1'
    $state = Get-Content -LiteralPath (Join-Path $private 'state.json') -Raw | ConvertFrom-Json
    Assert-ExportTest ($state.Stage -eq 'export-ready' -and $state.PrimaryResumed -and -not $global:ExportMock.Frozen) 'Successful export did not resume primary.'
    $manifest = Get-Content -LiteralPath (Join-Path $state.TransferDirectory 'manifest.json') -Raw | ConvertFrom-Json
    Assert-ExportTest ($manifest.Files.Count -eq 5 -and $manifest.PrimaryServerId -eq 1) 'Transfer manifest incorrect.'
    foreach ($file in $manifest.Files) {
        Assert-ExportTest ((Get-FileHash -LiteralPath (Join-Path $state.TransferDirectory $file.Path) -Algorithm SHA256).Hash -ceq $file.Sha256) 'Transfer hash mismatch.'
        Assert-ExportTest ($file.Path -notin @('ca-key.pem', 'server-key.pem', 'original-server-key.pem')) 'Primary private identity included in transfer.'
    }
    $password = [IO.File]::ReadAllText((Join-Path $state.TransferDirectory 'replication-password'))
    foreach ($command in $global:ExportMock.Calls) { Assert-ExportTest (-not (($command -join ' ').Contains($password))) 'Replication password exposed in CLI arguments.' }
    $runner = [IO.File]::ReadAllText((Join-Path $private 'root-file.sh'))
    Assert-ExportTest ($runner.Contains('mysql --user=root --password < "$1"') -and -not $runner.Contains("`r")) 'Root file runner or LF handling incorrect.'
    $setup = @($global:ExportMock.Sql | Where-Object { $_.Contains('CREATE USER') })[0]
    Assert-ExportTest ($setup.Contains('SET SESSION sql_log_bin = 0;') -and $setup.Contains("REQUIRE SUBJECT '/CN=loop-pc2-replica'")) 'Account is not local and certificate restricted.'
    $beforeSql = $global:ExportMock.Sql.Count
    Invoke-ExportFailure $casePath 'already exist'
    Assert-ExportTest ($global:ExportMock.Sql.Count -eq $beforeSql) 'Repeated export changed account or DB.'
    $beforeState = [IO.File]::ReadAllText((Join-Path $private 'state.json'))
    & $tool -RepositoryPath $casePath -Action Status
    Assert-ExportTest ([IO.File]::ReadAllText((Join-Path $private 'state.json')) -ceq $beforeState) 'Status changed export state.'
    Write-Host 'PASS: successful verified export, manifest hashes, limited transfer, CLI secret handling, resume, rerun refusal and read-only status'
    Write-Host 'PASS: 9 mock scenarios; no real Docker, MySQL or network calls'
}
finally {
    Remove-Item -LiteralPath Function:/docker -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name ExportMock -Scope Global -ErrorAction SilentlyContinue
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary cleanup target.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
