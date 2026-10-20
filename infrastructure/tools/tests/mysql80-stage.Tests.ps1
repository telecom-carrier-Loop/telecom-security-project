[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../mysql80-stage.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-mysql80-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot

function Assert-Stage([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function New-StageCase([string]$Name) {
    $casePath = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path $casePath
    $source = [PSCustomObject]@{
        Id = 'source-id'; Name = '/flask_mysql'; Image = 'image80'
        State = [PSCustomObject]@{ Running = $true; ExitCode = 0 }
        Mounts = @([PSCustomObject]@{ Type = 'volume'; Name = '7_test_class_mysql_data'; Destination = '/var/lib/mysql'; RW = $true })
        HostConfig = [PSCustomObject]@{ NetworkMode = 'bridge'; RestartPolicy = [PSCustomObject]@{ Name = 'unless-stopped'; MaximumRetryCount = 0 } }
        Config = [PSCustomObject]@{ Cmd = @('mysqld') }
        NetworkSettings = [PSCustomObject]@{ Ports = [PSCustomObject]@{ '3306/tcp' = @([PSCustomObject]@{ HostIp = '0.0.0.0'; HostPort = '3306' }) } }
    }
    $global:StageMock = @{
        Source = $source; Calls = [Collections.Generic.List[object]]::new()
        SqlFailure = $false; DumpFailure = $false; StopExit = 0
        BackupTables = 22; WrongCandidateVolume = $false; CloneVolume = ''; Candidate = $null
    }
    $casePath
}

# Shadow the CLI for the entire test. No actual Docker process is invoked.
function global:docker {
    $command = @($args)
    $global:LASTEXITCODE = 0
    $global:StageMock.Calls.Add($command)
    switch ($command[0]) {
        'inspect' {
            $container = $global:StageMock.Source
            if ($command[1] -eq 'candidate-id') { $container = $global:StageMock.Candidate }
            ConvertTo-Json -InputObject @($container) -Depth 12 -Compress
            return
        }
        'ps' { 'source-id'; return }
        'pull' { return }
        'image' { 'image84'; return }
        'exec' {
            if ($command -contains 'mysql' -and $global:StageMock.SqlFailure) { $global:LASTEXITCODE = 1 }
            if ($command -contains 'mysqldump' -and $global:StageMock.DumpFailure) { $global:LASTEXITCODE = 1 }
            return
        }
        'cp' {
            $headers = @(1..$global:StageMock.BackupTables | ForEach-Object { '-- Table structure for table table_' + $_ })
            [IO.File]::WriteAllLines($command[2], $headers, [Text.Encoding]::ASCII)
            return
        }
        'update' { return }
        'stop' {
            $global:StageMock.Source.State.Running = $false
            $global:StageMock.Source.State.ExitCode = $global:StageMock.StopExit
            return
        }
        'volume' { $global:StageMock.CloneVolume = $command[2]; return }
        'run' { return }
        'create' {
            $volume = $global:StageMock.CloneVolume
            if ($global:StageMock.WrongCandidateVolume) { $volume = '7_test_class_mysql_data' }
            $global:StageMock.Candidate = [PSCustomObject]@{
                Id = 'candidate-id'; Image = 'image84'
                Mounts = @([PSCustomObject]@{ Type = 'volume'; Name = $volume; Destination = '/var/lib/mysql'; RW = $true })
                HostConfig = [PSCustomObject]@{ NetworkMode = 'none' }
            }
            'candidate-id'
            return
        }
        'start' { return }
        default { throw ('Unexpected mock command: ' + $command[0]) }
    }
}

function Invoke-ExpectedFailure([string]$Path, [string]$Message) {
    $caught = ''
    try { & $tool -RepositoryPath $Path }
    catch { $caught = $_.Exception.Message }
    Assert-Stage ($caught -like ('*' + $Message + '*')) ('Expected failure: ' + $Message + '; got: ' + $caught)
}

function Assert-NoCommand([string]$Name) {
    Assert-Stage (@($global:StageMock.Calls | Where-Object { $_[0] -eq $Name }).Count -eq 0) ('Unexpected command: ' + $Name)
}

try {
    $casePath = New-StageCase 'wrong-publisher'
    $global:StageMock.Source.NetworkSettings.Ports.'3306/tcp'[0].HostPort = '3307'
    Invoke-ExpectedFailure $casePath 'not the actual 3306'
    Assert-NoCommand 'exec'
    Assert-NoCommand 'stop'
    Write-Host 'PASS: wrong 3306 publisher fails before SQL or shutdown'

    $casePath = New-StageCase 'source-check-failure'
    $global:StageMock.SqlFailure = $true
    Invoke-ExpectedFailure $casePath 'Docker exec failed'
    Assert-NoCommand 'cp'
    Assert-NoCommand 'stop'
    Write-Host 'PASS: SQL check failure prevents backup and shutdown'

    $casePath = New-StageCase 'backup-failure'
    $global:StageMock.DumpFailure = $true
    Invoke-ExpectedFailure $casePath 'Docker exec failed'
    Assert-NoCommand 'stop'
    Write-Host 'PASS: dump failure preserves the running original'

    $casePath = New-StageCase 'incomplete-backup'
    $global:StageMock.BackupTables = 7
    Invoke-ExpectedFailure $casePath 'confirmed 22 tables'
    Assert-NoCommand 'stop'
    Write-Host 'PASS: old seven-table backup cannot pass the current baseline'

    $casePath = New-StageCase 'unclean-shutdown'
    $global:StageMock.StopExit = 137
    Invoke-ExpectedFailure $casePath 'did not shut down cleanly'
    Assert-NoCommand 'run'
    Assert-NoCommand 'create'
    Write-Host 'PASS: forced shutdown prevents copying and upgrade'

    $casePath = New-StageCase 'wrong-candidate-volume'
    $global:StageMock.WrongCandidateVolume = $true
    Invoke-ExpectedFailure $casePath 'Candidate safety check failed'
    Assert-NoCommand 'start'
    Write-Host 'PASS: original volume cannot be started under MySQL 8.4'

    $casePath = New-StageCase 'success'
    & $tool -RepositoryPath $casePath
    $state = Get-Content -LiteralPath (Join-Path $casePath '.secrets/mysql80-upgrade/state.json') -Raw | ConvertFrom-Json
    Assert-Stage ($state.Stage -eq 'candidate-started') 'Candidate stage not saved.'
    Assert-Stage ($state.SourceRestartPolicy.Name -eq 'unless-stopped') 'Original restart policy not preserved.'
    Assert-Stage (Test-Path -LiteralPath ($state.BackupFile + '.sha256')) 'Backup hash missing.'
    $copy = @($global:StageMock.Calls | Where-Object { $_[0] -eq 'run' })[0]
    Assert-Stage ($copy -contains 'type=volume,source=7_test_class_mysql_data,target=/from,readonly') 'Source copy mount is not read only.'
    Assert-Stage ($copy -contains ('type=volume,source=' + $state.CloneVolume + ',target=/to')) 'Copy destination is not the new volume.'
    $create = @($global:StageMock.Calls | Where-Object { $_[0] -eq 'create' })[0]
    Assert-Stage ($create -contains ('type=volume,source=' + $state.CloneVolume + ',target=/var/lib/mysql')) 'Candidate does not use the clone.'
    Assert-Stage (-not ($create -contains '-p') -and -not ($create -contains '--publish')) 'Candidate publishes a host port.'
    Assert-NoCommand 'rm'
    Assert-NoCommand 'rename'
    $callCount = $global:StageMock.Calls.Count
    Invoke-ExpectedFailure $casePath 'state already exists'
    Assert-Stage ($global:StageMock.Calls.Count -eq $callCount) 'Repeated staging made Docker changes.'
    Write-Host 'PASS: success preserves original, records backup, isolates clone and blocks reruns'
    Write-Host 'PASS: 7 mock scenarios; no real Docker, MySQL or network calls'
}
finally {
    Remove-Item -LiteralPath Function:/docker -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name StageMock -Scope Global -ErrorAction SilentlyContinue
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary cleanup target.' }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
