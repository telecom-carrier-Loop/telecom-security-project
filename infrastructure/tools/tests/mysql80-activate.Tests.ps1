[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../mysql80-activate.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-mysql80-activate-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$testCount = 0
$utf8 = [Text.UTF8Encoding]::new($false)
$serverArguments = @('--server-id=1', '--lower-case-table-names=0', '--innodb-page-size=16384', '--character-set-server=utf8mb4', '--collation-server=utf8mb4_0900_ai_ci', '--innodb-buffer-pool-size=256M', '--event-scheduler=OFF')

function Assert-ActivationTest([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function New-ActivationCase([string]$Name) {
    $casePath = Join-Path $testRoot $Name
    $private = Join-Path $casePath '.secrets/mysql80-upgrade'
    $null = New-Item -ItemType Directory -Path $private -Force
    $backup = Join-Path $private 'pc1-current-22-tables.sql'
    [IO.File]::WriteAllText($backup, 'mock backup with no application data', $utf8)
    [IO.File]::WriteAllText(($backup + '.sha256'), (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash, [Text.Encoding]::ASCII)
    $state = [PSCustomObject]@{
        Stage = 'candidate-started'; SourceId = 'source-id'; SourceName = 'flask_mysql'
        SourceVolume = '7_test_class_mysql_data'; SourceImageId = 'image80'; TargetImageId = 'image84'
        SourceRestartPolicy = [PSCustomObject]@{ Name = 'unless-stopped'; MaximumRetryCount = 0 }
        CandidateName = 'candidate-name'; CandidateId = 'candidate-id'; CloneVolume = 'upgraded-clone'
        ExpectedTables = 22; BackupFile = $backup; RollbackName = 'flask_mysql-80-rollback-test'
    }
    [IO.File]::WriteAllText((Join-Path $private 'state.json'), ($state | ConvertTo-Json -Depth 8), $utf8)
    $source = [PSCustomObject]@{
        Id = 'source-id'; Name = '/flask_mysql'; Image = 'image80'
        State = [PSCustomObject]@{ Running = $false; ExitCode = 0 }
        Mounts = @([PSCustomObject]@{ Type = 'volume'; Name = '7_test_class_mysql_data'; Destination = '/var/lib/mysql'; RW = $true })
        HostConfig = [PSCustomObject]@{ RestartPolicy = [PSCustomObject]@{ Name = 'no' } }
    }
    $candidate = [PSCustomObject]@{
        Id = 'candidate-id'; Name = '/candidate-name'; Image = 'image84'
        State = [PSCustomObject]@{ Running = $true; ExitCode = 0 }
        Mounts = @([PSCustomObject]@{ Type = 'volume'; Name = 'upgraded-clone'; Destination = '/var/lib/mysql'; RW = $true })
        HostConfig = [PSCustomObject]@{ NetworkMode = 'none'; RestartPolicy = [PSCustomObject]@{ Name = 'no' } }
        Config = [PSCustomObject]@{ Cmd = $serverArguments }
    }
    $global:ActivationMock = @{
        Source = $source; Candidate = $candidate; Production = $null
        Calls = [Collections.Generic.List[object]]::new(); Sql = [Collections.Generic.List[string]]::new()
        PortConflict = $false; WindowsListener = $false; SourceWriter = $false; CloneWriter = $false
        LateCloneWriter = $false; RollbackConflict = $false; SqlFailure = $false; VerifySqlFailure = $false
        StopExit = 0; WrongProductionMount = $false; WrongProductionPort = $false; RestartPolicy = 'no'
    }
    $casePath
}

# Both functions shadow native facilities. Unexpected commands fail instead of falling through.
function global:Get-NetTCPConnection {
    if ($global:ActivationMock.WindowsListener) { [PSCustomObject]@{ LocalPort = 3306; OwningProcess = 123 } }
}

function global:docker {
    $command = @($args)
    $global:LASTEXITCODE = 0
    $global:ActivationMock.Calls.Add($command)
    switch ($command[0]) {
        'inspect' {
            if ($command -contains '--format') { 'mock container status'; return }
            $container = switch ($command[1]) {
                'source-id' { $global:ActivationMock.Source }
                'candidate-id' { $global:ActivationMock.Candidate }
                'production-id' { $global:ActivationMock.Production }
                default { throw 'Unexpected inspect ID.' }
            }
            ConvertTo-Json -InputObject @($container) -Depth 12 -Compress
            return
        }
        'ps' {
            $filterIndex = [Array]::IndexOf($command, '--filter')
            if ($filterIndex -lt 0) { throw 'Mock ps requires a filter.' }
            $filter = [string]$command[$filterIndex + 1]
            switch ($filter) {
                'volume=7_test_class_mysql_data' {
                    if ($global:ActivationMock.SourceWriter) { 'rogue-source-writer' }
                }
                'volume=upgraded-clone' {
                    if ($global:ActivationMock.Candidate.State.Running) { 'candidate-id' }
                    if ($null -ne $global:ActivationMock.Production -and $global:ActivationMock.Production.State.Running) { 'production-id' }
                    if ($global:ActivationMock.CloneWriter -or ($global:ActivationMock.LateCloneWriter -and -not $global:ActivationMock.Candidate.State.Running)) { 'rogue-clone-writer' }
                }
                'publish=3306' {
                    if ($global:ActivationMock.PortConflict) { 'foreign-publisher' }
                    if ($null -ne $global:ActivationMock.Production -and $global:ActivationMock.Production.State.Running) { 'production-id' }
                }
                'name=^/flask_mysql-80-rollback-test$' {
                    if ($global:ActivationMock.RollbackConflict) { 'existing-rollback-id' }
                }
                default { throw ('Unexpected mock ps filter: ' + $filter) }
            }
            return
        }
        'exec' {
            if ($command[2] -ne 'candidate-id' -and $command[2] -ne 'production-id') { throw 'Unexpected exec ID.' }
            $sql = [string]$command[$command.Count - 1]
            $global:ActivationMock.Sql.Add($sql)
            if ($global:ActivationMock.SqlFailure -or ($command[2] -eq 'production-id' -and $global:ActivationMock.VerifySqlFailure)) { $global:LASTEXITCODE = 1 }
            return
        }
        'stop' {
            if ($command[$command.Count - 1] -ne 'candidate-id') { throw 'Attempt to stop a protected container.' }
            $global:ActivationMock.Candidate.State.Running = $false
            $global:ActivationMock.Candidate.State.ExitCode = $global:ActivationMock.StopExit
            return
        }
        'rename' {
            if ($command[1] -ne 'source-id' -or $command[2] -ne 'flask_mysql-80-rollback-test') { throw 'Unexpected rename.' }
            $global:ActivationMock.Source.Name = '/' + $command[2]
            return
        }
        'create' {
            $volume = 'upgraded-clone'
            if ($global:ActivationMock.WrongProductionMount) { $volume = '7_test_class_mysql_data' }
            $port = '3306'
            if ($global:ActivationMock.WrongProductionPort) { $port = '3307' }
            $cmdStart = [Array]::IndexOf($command, 'image84')
            if ($cmdStart -lt 0) { throw 'Expected pinned image ID.' }
            $global:ActivationMock.Production = [PSCustomObject]@{
                Id = 'production-id'; Name = '/flask_mysql'; Image = 'image84'
                State = [PSCustomObject]@{ Running = $false; ExitCode = 0 }
                Mounts = @([PSCustomObject]@{ Type = 'volume'; Name = $volume; Destination = '/var/lib/mysql'; RW = $true })
                HostConfig = [PSCustomObject]@{ NetworkMode = 'bridge'; PortBindings = [PSCustomObject]@{ '3306/tcp' = @([PSCustomObject]@{ HostIp = '0.0.0.0'; HostPort = $port }) } }
                Config = [PSCustomObject]@{ Cmd = @($command[($cmdStart + 1)..($command.Count - 1)]) }
            }
            'production-id'
            return
        }
        'start' {
            if ($command[1] -ne 'production-id') { throw 'Attempt to start a protected container.' }
            $global:ActivationMock.Production.State.Running = $true
            return
        }
        'update' {
            if ($command[1] -ne '--restart=unless-stopped' -or $command[2] -ne 'production-id') { throw 'Unexpected restart policy mutation.' }
            $global:ActivationMock.RestartPolicy = 'unless-stopped'
            return
        }
        default { throw ('Unexpected mock Docker command: ' + $command[0]) }
    }
}

function Invoke-ExpectedFailure([string]$Path, [string]$Action, [string]$Message) {
    $caught = ''
    try { & $tool -RepositoryPath $Path -Action $Action }
    catch { $caught = $_.Exception.Message }
    Assert-ActivationTest ($caught -like ('*' + $Message + '*')) ('Expected failure: ' + $Message + '; got: ' + $caught)
}

function Assert-NoActivationCommand([string]$Name) {
    Assert-ActivationTest (@($global:ActivationMock.Calls | Where-Object { $_[0] -eq $Name }).Count -eq 0) ('Unexpected command: ' + $Name)
}

function Complete-ActivationCase([string]$Message) {
    $script:testCount++
    Write-Host ('PASS: ' + $Message)
}

try {
    $casePath = New-ActivationCase 'original-auto-restart'
    $global:ActivationMock.Source.HostConfig.RestartPolicy.Name = 'always'
    Invoke-ExpectedFailure $casePath 'Activate' 'restart'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'original automatic restart blocks activation'

    $casePath = New-ActivationCase 'candidate-auto-restart'
    $global:ActivationMock.Candidate.HostConfig.RestartPolicy.Name = 'unless-stopped'
    Invoke-ExpectedFailure $casePath 'Activate' 'restart'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'candidate automatic restart blocks activation'

    $casePath = New-ActivationCase 'docker-port-conflict'
    $global:ActivationMock.PortConflict = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'already published'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'Docker 3306 conflict fails before SQL or stop'

    $casePath = New-ActivationCase 'windows-port-conflict'
    $global:ActivationMock.WindowsListener = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'Windows port 3306 is busy'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'native Windows listener fails before SQL or stop'

    $casePath = New-ActivationCase 'original-shared-writer'
    $global:ActivationMock.SourceWriter = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'protected volume is still in use'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'original volume writer blocks activation'

    $casePath = New-ActivationCase 'clone-shared-writer'
    $global:ActivationMock.CloneWriter = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'running user of the clone'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'extra clone writer blocks activation'

    $casePath = New-ActivationCase 'rollback-name-conflict'
    $global:ActivationMock.RollbackConflict = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'Rollback container name'
    Assert-NoActivationCommand 'stop'
    Assert-NoActivationCommand 'rename'
    Complete-ActivationCase 'rollback name collision preserves source identity'

    $casePath = New-ActivationCase 'backup-hash-mismatch'
    [IO.File]::AppendAllText((Join-Path $casePath '.secrets/mysql80-upgrade/pc1-current-22-tables.sql'), 'changed', $utf8)
    Invoke-ExpectedFailure $casePath 'Activate' 'backup hash mismatch'
    Assert-NoActivationCommand 'exec'
    Assert-NoActivationCommand 'stop'
    Complete-ActivationCase 'backup tampering blocks activation before database mutation'

    $casePath = New-ActivationCase 'sql-failure'
    $global:ActivationMock.SqlFailure = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'Docker exec failed'
    Assert-NoActivationCommand 'stop'
    Assert-NoActivationCommand 'rename'
    Complete-ActivationCase 'candidate SQL failure prevents shutdown and rename'

    $casePath = New-ActivationCase 'unclean-stop'
    $global:ActivationMock.StopExit = 137
    Invoke-ExpectedFailure $casePath 'Activate' 'did not stop cleanly'
    Assert-NoActivationCommand 'rename'
    Assert-NoActivationCommand 'create'
    Complete-ActivationCase 'unclean candidate stop blocks production creation'

    $casePath = New-ActivationCase 'late-clone-writer'
    $global:ActivationMock.LateCloneWriter = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'protected volume is still in use'
    Assert-NoActivationCommand 'rename'
    Assert-NoActivationCommand 'create'
    Complete-ActivationCase 'writer appearing after stop blocks production creation'

    $casePath = New-ActivationCase 'wrong-production-volume'
    $global:ActivationMock.WrongProductionMount = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'Unexpected data mount'
    Assert-NoActivationCommand 'start'
    Complete-ActivationCase 'accidental original volume mount cannot be started'

    $casePath = New-ActivationCase 'wrong-production-port'
    $global:ActivationMock.WrongProductionPort = $true
    Invoke-ExpectedFailure $casePath 'Activate' 'Unexpected production port binding'
    Assert-NoActivationCommand 'start'
    Complete-ActivationCase 'wrong production port cannot be started'

    $casePath = New-ActivationCase 'verify-sql-failure'
    & $tool -RepositoryPath $casePath -Action Activate
    $global:ActivationMock.VerifySqlFailure = $true
    Invoke-ExpectedFailure $casePath 'Verify' 'Docker exec failed'
    Assert-NoActivationCommand 'update'
    $statePath = Join-Path $casePath '.secrets/mysql80-upgrade/state.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ActivationTest ($state.Stage -eq 'production-started') 'SQL failure incorrectly marked service ready.'
    Assert-ActivationTest ($global:ActivationMock.RestartPolicy -eq 'no') 'SQL failure enabled automatic restart.'
    Complete-ActivationCase 'failed Verify leaves service unready and restart disabled'

    $casePath = New-ActivationCase 'success-and-readonly-status'
    & $tool -RepositoryPath $casePath -Action Activate
    $statePath = Join-Path $casePath '.secrets/mysql80-upgrade/state.json'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ActivationTest ($state.Stage -eq 'production-started' -and $state.ProductionId -eq 'production-id') 'Production identity/stage not saved.'
    Assert-ActivationTest (-not $global:ActivationMock.Source.State.Running -and -not $global:ActivationMock.Candidate.State.Running) 'Old containers did not remain stopped.'
    Assert-ActivationTest ($global:ActivationMock.Source.Name -eq '/flask_mysql-80-rollback-test') 'Original not preserved under rollback name.'
    Assert-ActivationTest ($global:ActivationMock.Sql[0].Contains('SET PERSIST super_read_only = ON;')) 'Activation did not persist the write lock.'
    Assert-NoActivationCommand 'update'
    $stopCount = @($global:ActivationMock.Calls | Where-Object { $_[0] -eq 'stop' }).Count
    $createCount = @($global:ActivationMock.Calls | Where-Object { $_[0] -eq 'create' }).Count
    Invoke-ExpectedFailure $casePath 'Activate' 'Do not repeat'
    Assert-ActivationTest (@($global:ActivationMock.Calls | Where-Object { $_[0] -eq 'stop' }).Count -eq $stopCount) 'Repeated activation stopped a container.'
    Assert-ActivationTest (@($global:ActivationMock.Calls | Where-Object { $_[0] -eq 'create' }).Count -eq $createCount) 'Repeated activation created a container.'
    & $tool -RepositoryPath $casePath -Action Verify
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    Assert-ActivationTest ($state.Stage -eq 'service-ready') 'Verify did not mark service ready.'
    Assert-ActivationTest ($global:ActivationMock.RestartPolicy -eq 'unless-stopped') 'Verify did not save restart policy.'
    Assert-ActivationTest ($global:ActivationMock.Sql[1].Contains('SET PERSIST super_read_only = OFF;')) 'Verify did not release persisted write lock.'
    Assert-NoActivationCommand 'rm'
    $beforeState = [IO.File]::ReadAllText($statePath)
    $beforeCalls = $global:ActivationMock.Calls.Count
    & $tool -RepositoryPath $casePath -Action Status
    Assert-ActivationTest ([IO.File]::ReadAllText($statePath) -ceq $beforeState) 'Status changed the state file.'
    foreach ($call in @($global:ActivationMock.Calls | Select-Object -Skip $beforeCalls)) {
        Assert-ActivationTest ($call[0] -in @('inspect', 'ps')) 'Status made a mutating Docker call.'
    }
    Complete-ActivationCase 'Activate -> Verify succeeds, rerun is blocked, Status is read only and script exit returns to runner'
    Write-Host ('PASS: ' + $testCount + ' activation mock scenarios; no real Docker, MySQL or network calls')
}
finally {
    Remove-Item -LiteralPath Function:/docker -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath Function:/Get-NetTCPConnection -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name ActivationMock -Scope Global -ErrorAction SilentlyContinue
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) { throw 'Unsafe temporary cleanup target.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
