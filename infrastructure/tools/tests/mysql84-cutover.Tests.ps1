[CmdletBinding()]
param(
    [string]$ScriptPath = ''
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ([string]::IsNullOrWhiteSpace($ScriptPath)) {
    $ScriptPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '../mysql84-cutover.ps1'
}
$ScriptPath = (Resolve-Path -LiteralPath $ScriptPath).Path
$testUtf8 = [Text.UTF8Encoding]::new($false)
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-cutover-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$testCount = 0

function Assert-Loop([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw ('ASSERT: ' + $Message) }
}

function Write-TestText([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText($Path, $Text, $testUtf8)
}

function New-TestCase([string]$Name, [switch]$SameVolume, [switch]$BadProbe) {
    $caseRoot = Join-Path $testRoot $Name
    $null = New-Item -ItemType Directory -Path (Join-Path $caseRoot 'backend') -Force
    $sourceMount = [PSCustomObject]@{
        Type = 'volume'; Name = 'original-data'; Source = '/volumes/original-data';
        Destination = '/var/lib/mysql'; RW = $true
    }
    $candidateMount = [PSCustomObject]@{
        Type = 'volume'; Name = 'candidate-data'; Source = '/volumes/candidate-data';
        Destination = '/var/lib/mysql'; RW = $true
    }
    if ($SameVolume) { $candidateMount.Source = $sourceMount.Source }
    $source = [PSCustomObject]@{
        Id = 'source-id'; Image = 'image26';
        State = [PSCustomObject]@{ Running = $true; ExitCode = 0 };
        NetworkSettings = [PSCustomObject]@{
            Ports = [PSCustomObject]@{
                '3306/tcp' = @([PSCustomObject]@{ HostIp = '0.0.0.0'; HostPort = '3306' })
            }
        };
        Mounts = @($sourceMount);
        HostConfig = [PSCustomObject]@{
            NetworkMode = 'bridge';
            RestartPolicy = [PSCustomObject]@{ Name = 'unless-stopped'; MaximumRetryCount = 0 }
        };
        Config = [PSCustomObject]@{ Cmd = @('--server-id=1') }
    }
    $candidate = [PSCustomObject]@{
        Id = 'candidate-id'; Image = 'image84';
        State = [PSCustomObject]@{ Running = $true; ExitCode = 0 };
        Mounts = @($candidateMount, [PSCustomObject]@{
            Type = 'bind'; Name = ''; Source = '/private/original-root-password';
            Destination = '/run/secrets/root-password'; RW = $false
        });
        HostConfig = [PSCustomObject]@{ NetworkMode = 'none' };
        Config = [PSCustomObject]@{ Cmd = @('--server-id=1', '--gtid-mode=ON') }
    }
    $global:LoopDockerMock = @{
        Containers = @{ 'mysql-server' = $source; 'source-id' = $source; 'candidate-test' = $candidate; 'candidate-id' = $candidate };
        Calls = [Collections.Generic.List[object]]::new();
        Sql = [Collections.Generic.List[object]]::new();
        Files = @{}; BadProbe = [bool]$BadProbe; EnableSwitch = $false;
        CandidateStopExit = 0; ProductionWrongMount = $false; StartPortConflict = $false
    }
    return $caseRoot
}

# This function shadows the CLI. Never invoke a real Docker process.
function global:docker {
    $command = @($args)
    $global:LASTEXITCODE = 0
    $global:LoopDockerMock.Calls.Add($command)
    switch ($command[0]) {
        'inspect' {
            $name = [string]$command[1]
            if (-not $global:LoopDockerMock.Containers.ContainsKey($name)) {
                throw 'Mock inspect received an unknown container.'
            }
            ConvertTo-Json -InputObject @($global:LoopDockerMock.Containers[$name]) -Depth 12 -Compress
            return
        }
        'cp' {
            $source = [string]$command[1]
            $destination = [string]$command[2]
            if ($source -match '^candidate-id:/') {
                if ($source.EndsWith('/mysql-run-file.sh')) {
                    [IO.File]::WriteAllText($destination, "#!/bin/sh`nexit 0`n")
                    return
                }
                if ($source.EndsWith('/root-password')) {
                    [IO.File]::WriteAllText($destination, ('a' * 64))
                    return
                }
                throw 'Mock container copy source is unsupported.'
            }
            $global:LoopDockerMock.Files[$destination] = [IO.File]::ReadAllText($source)
            return
        }
        'exec' {
            if ($command[2] -in @('chmod', 'rm')) { return }
            if ($command[2] -ne 'sh') { throw 'Mock exec command is unsupported.' }
            $key = [string]$command[1] + ':' + [string]$command[4]
            if (-not $global:LoopDockerMock.Files.ContainsKey($key)) {
                throw 'Mock SQL file was not copied.'
            }
            $sql = $global:LoopDockerMock.Files[$key]
            $global:LoopDockerMock.Sql.Add([PSCustomObject]@{ Container = $command[1]; Text = $sql })
            if ($sql.Contains('LOOP_PRIMARY_READY')) {
                if ($global:LoopDockerMock.BadProbe) { 'LOOP_PRIMARY_MISMATCH'; return }
                'LOOP_PRIMARY_READY'
                return
            }
            if ($sql.Contains('LOOP_APP_ACCOUNT_READY')) { 'LOOP_APP_ACCOUNT_READY'; return }
            throw 'Mock SQL content is unsupported.'
        }
        'update' {
            if (-not $global:LoopDockerMock.EnableSwitch) { throw 'Unexpected Docker update.' }
            return
        }
        'stop' {
            if (-not $global:LoopDockerMock.EnableSwitch) { throw 'Unexpected Docker stop.' }
            $id = [string]$command[-1]
            $item = $global:LoopDockerMock.Containers[$id]
            $item.State.Running = $false
            $item.State.ExitCode = 0
            if ($id -eq 'candidate-id') { $item.State.ExitCode = $global:LoopDockerMock.CandidateStopExit }
            return
        }
        'rename' {
            if (-not $global:LoopDockerMock.EnableSwitch) { throw 'Unexpected Docker rename.' }
            $global:LoopDockerMock.Containers[[string]$command[2]] = $global:LoopDockerMock.Containers[[string]$command[1]]
            $global:LoopDockerMock.Containers.Remove('mysql-server')
            return
        }
        'create' {
            if (-not $global:LoopDockerMock.EnableSwitch) { throw 'Unexpected Docker create.' }
            $candidateData = $global:LoopDockerMock.Containers['candidate-id'].Mounts[0]
            $newSource = $candidateData.Source
            if ($global:LoopDockerMock.ProductionWrongMount) { $newSource = '/volumes/unexpected-data' }
            $production = [PSCustomObject]@{
                Id = 'production-id'; State = [PSCustomObject]@{ Running = $false; ExitCode = 0 };
                Mounts = @(
                    [PSCustomObject]@{
                        Type = 'volume'; Name = $candidateData.Name; Source = $newSource;
                        Destination = '/var/lib/mysql'; RW = $true
                    },
                    [PSCustomObject]@{
                        Type = 'bind'; Source = '/private/copied-root-password';
                        Destination = '/run/secrets/root-password'; RW = $false
                    }
                )
            }
            $global:LoopDockerMock.Containers['production-id'] = $production
            $global:LoopDockerMock.Containers['mysql-server'] = $production
            'production-id'
            return
        }
        'start' {
            if (-not $global:LoopDockerMock.StartPortConflict) { throw 'Unexpected Docker start.' }
            'Bind for 0.0.0.0:3306 failed: port is already allocated'
            $global:LASTEXITCODE = 1
            return
        }
        default { throw 'Unexpected Docker mutation or unsupported mock command.' }
    }
}

function Invoke-TestAction([string]$Action, [string]$Repository) {
    & $ScriptPath -Action $Action -RepositoryPath $Repository -CandidateName 'candidate-test' *> $null
}

function Assert-NoContainerMutation {
    $mutations = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -in @('stop', 'create', 'start', 'rename', 'rm', 'update') })
    Assert-Loop ($mutations.Count -eq 0) 'Unexpected container mutation.'
}

function New-PreparedSwitchCase([string]$Name) {
    $caseRoot = New-TestCase $Name
    Invoke-TestAction 'prepare' $caseRoot
    $global:LoopDockerMock.Calls.Clear()
    $global:LoopDockerMock.Sql.Clear()
    $global:LoopDockerMock.EnableSwitch = $true
    return $caseRoot
}

try {
    # Actual runtime publishing must establish the original database identity.
    $caseRoot = New-TestCase 'source-without-active-publish'
    $global:LoopDockerMock.Containers['mysql-server'].NetworkSettings.Ports = [PSCustomObject]@{}
    $caught = $false
    try { Invoke-TestAction 'prepare' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*does not actively publish*') 'Wrong unpublished-source error.'
    }
    Assert-Loop $caught 'Unpublished original was accepted as the Flask database.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 0) 'Wrong source reached SQL.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: inactive host publishing blocks prepare before SQL'

    $caseRoot = New-TestCase 'source-on-different-host-port'
    $global:LoopDockerMock.Containers['mysql-server'].NetworkSettings.Ports.'3306/tcp'[0].HostPort = '3307'
    $caught = $false
    try { Invoke-TestAction 'prepare' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*does not actively publish*') 'Wrong host-port error.'
    }
    Assert-Loop $caught 'A different host port was accepted as 3306.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 0) 'Wrong host port reached SQL.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: a different host port cannot identify the Flask database'

    # Guard 1: sharing a data volume must fail before any SQL or mutation.
    $caseRoot = New-TestCase 'same-volume' -SameVolume
    $caught = $false
    try { Invoke-TestAction 'prepare' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*different data volumes*') 'Wrong same-volume error.'
    }
    Assert-Loop $caught 'Same-volume prepare unexpectedly succeeded.'
    Assert-Loop ($global:LoopDockerMock.Calls.Count -eq 2) 'Same-volume guard must only inspect.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 0) 'Same-volume guard executed SQL.'
    Assert-Loop (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.secrets/mysql84-cutover/state.json'))) 'Unsafe state was saved.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: same-volume prepare stops before SQL and mutations'

    # Guard 2: failed server settings must not create or alter app accounts.
    $caseRoot = New-TestCase 'bad-probe' -BadProbe
    $caught = $false
    try { Invoke-TestAction 'prepare' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*version or settings*') 'Wrong probe mismatch error.'
    }
    Assert-Loop $caught 'Bad-probe prepare unexpectedly succeeded.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 1) 'Bad-probe prepare executed additional SQL.'
    $accountSql = @($global:LoopDockerMock.Sql | Where-Object Text -match '(?i)(CREATE|ALTER)\s+USER')
    Assert-Loop ($accountSql.Count -eq 0) 'Account SQL ran after failed probe.'
    Assert-Loop (-not (Test-Path -LiteralPath (Join-Path $caseRoot '.secrets/mysql84-cutover/app-password'))) 'App secret generated after failed probe.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: probe mismatch prevents app-account changes'

    # Success: prepare creates private state and a least-privilege app account.
    $caseRoot = New-TestCase 'prepare-success'
    Invoke-TestAction 'prepare' $caseRoot
    $private = Join-Path $caseRoot '.secrets/mysql84-cutover'
    $state = Get-Content -LiteralPath (Join-Path $private 'state.json') -Raw | ConvertFrom-Json
    Assert-Loop ($state.Stage -eq 'prepared') 'Successful prepare did not save stage.'
    Assert-Loop ($state.SourceId -eq 'source-id' -and $state.CandidateId -eq 'candidate-id') 'Wrong prepared container identities.'
    Assert-Loop ($state.DataVolume -eq 'candidate-data') 'Wrong prepared data volume.'
    $appSecret = [IO.File]::ReadAllText((Join-Path $private 'app-password'))
    Assert-Loop ($appSecret -match '^[0-9a-f]{64}$') 'App secret format is invalid.'
    $accountSql = @($global:LoopDockerMock.Sql | Where-Object Text -match '(?i)ALTER\s+USER')
    Assert-Loop ($accountSql.Count -eq 1) 'App account SQL did not run exactly once.'
    Assert-Loop ($accountSql[0].Container -eq 'candidate-id') 'App account SQL reached original server.'
    Assert-Loop ($accountSql[0].Text.Contains('ON `my\_new\_board\_db`.*')) 'App grant is not limited to the literal database name.'
    Assert-Loop (-not $accountSql[0].Text.Contains('ALL PRIVILEGES')) 'App account was overprivileged.'
    Assert-Loop (-not (Test-Path -LiteralPath (Join-Path $private 'create-app-account.sql'))) 'Plaintext account SQL was retained.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: prepare saves state and changes only candidate app account'

    $caseRoot = New-PreparedSwitchCase 'switch-source-no-longer-published'
    $global:LoopDockerMock.Containers['mysql-server'].NetworkSettings.Ports = [PSCustomObject]@{}
    $caught = $false
    try { Invoke-TestAction 'switch' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*does not actively publish*') 'Wrong switched source-port error.'
    }
    Assert-Loop $caught 'Switch accepted a source whose published endpoint disappeared.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 0) 'Changed source publishing reached SQL.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: lost source publishing blocks switch before any shutdown'

    # Switch guard 1: original identity must still match the prepared state.
    $caseRoot = New-PreparedSwitchCase 'switch-source-identity'
    $global:LoopDockerMock.Containers['mysql-server'].Id = 'unexpected-source-id'
    $caught = $false
    try { Invoke-TestAction 'switch' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*identity changed*') 'Wrong original-identity error.'
    }
    Assert-Loop $caught 'Changed source identity unexpectedly accepted.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 0) 'Changed identity reached SQL.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: switch identity mismatch stops before updates or shutdown'

    # Switch guard 2: an unclean candidate shutdown must preserve the running original.
    $caseRoot = New-PreparedSwitchCase 'switch-unclean-candidate'
    $global:LoopDockerMock.CandidateStopExit = 137
    $caught = $false
    try { Invoke-TestAction 'switch' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*Candidate did not shut down cleanly*') 'Wrong candidate-shutdown error.'
    }
    Assert-Loop $caught 'Unclean candidate shutdown unexpectedly accepted.'
    $sourceStops = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -eq 'stop' -and $_[-1] -eq 'source-id' })
    $renames = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -eq 'rename' })
    $creates = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -eq 'create' })
    Assert-Loop ($sourceStops.Count -eq 0 -and $renames.Count -eq 0 -and $creates.Count -eq 0) 'Unclean candidate affected the original or created production.'
    Assert-Loop $global:LoopDockerMock.Containers['source-id'].State.Running 'Original was stopped after unclean candidate shutdown.'
    $state = Get-Content -LiteralPath (Join-Path $caseRoot '.secrets/mysql84-cutover/state.json') -Raw | ConvertFrom-Json
    Assert-Loop ($state.Stage -eq 'prepared') 'Unclean candidate saved a later stage.'
    $testCount++
    Write-Host 'PASS: candidate exit 137 preserves original without stop or rename'

    # Switch guard 3: wrong production mounts must fail before mysqld can start.
    $caseRoot = New-PreparedSwitchCase 'switch-wrong-production-mount'
    $global:LoopDockerMock.ProductionWrongMount = $true
    $caught = $false
    try { Invoke-TestAction 'switch' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*Production data mount mismatch*') 'Wrong production-mount error.'
    }
    Assert-Loop $caught 'Wrong production mount unexpectedly accepted.'
    $starts = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -eq 'start' })
    $deletions = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -eq 'rm' })
    Assert-Loop ($starts.Count -eq 0) 'Wrong-mounted production was started.'
    Assert-Loop ($deletions.Count -eq 0) 'A container was deleted on production-mount failure.'
    Assert-Loop $global:LoopDockerMock.Containers.ContainsKey('source-id') 'Original container was lost.'
    Assert-Loop (-not $global:LoopDockerMock.Containers['production-id'].State.Running) 'Wrong-mounted production is running.'
    $state = Get-Content -LiteralPath (Join-Path $caseRoot '.secrets/mysql84-cutover/state.json') -Raw | ConvertFrom-Json
    Assert-Loop ($state.Stage -eq 'created' -and $state.NewId -eq 'production-id') 'Mount failure did not retain created recovery state.'
    Assert-Loop $global:LoopDockerMock.Containers.ContainsKey($state.RollbackName) 'Original rollback container was not preserved.'
    $testCount++
    Write-Host 'PASS: wrong production mount prevents start and preserves rollback state'

    $caseRoot = New-PreparedSwitchCase 'switch-docker-port-conflict'
    $global:LoopDockerMock.StartPortConflict = $true
    $caught = $false
    try { Invoke-TestAction 'switch' $caseRoot }
    catch {
        $caught = $true
        Assert-Loop ($_.Exception.Message -like '*Bind for 0.0.0.0:3306 failed*') 'Docker start error was hidden.'
    }
    Assert-Loop $caught 'Port conflict unexpectedly succeeded.'
    $state = Get-Content -LiteralPath (Join-Path $caseRoot '.secrets/mysql84-cutover/state.json') -Raw | ConvertFrom-Json
    Assert-Loop ($state.Stage -eq 'created') 'Failed start advanced the cutover stage.'
    $deletions = @($global:LoopDockerMock.Calls | Where-Object { $_[0] -eq 'rm' })
    Assert-Loop ($deletions.Count -eq 0) 'Failed start deleted a recovery container.'
    Assert-Loop $global:LoopDockerMock.Containers.ContainsKey($state.RollbackName) 'Failed start lost the original.'
    $testCount++
    Write-Host 'PASS: port conflict retains recovery state and exposes the Docker error'

    # Configure must preserve unrelated settings and the first original backup.
    $caseRoot = New-TestCase 'configure'
    $private = Join-Path $caseRoot '.secrets/mysql84-cutover'
    $null = New-Item -ItemType Directory -Path $private -Force
    $password = 'b' * 64
    Write-TestText (Join-Path $private 'app-password') $password
    $state = [PSCustomObject]@{ Stage = 'switched'; NewId = 'production-id'; Configured = $false }
    Write-TestText (Join-Path $private 'state.json') ($state | ConvertTo-Json)
    $global:LoopDockerMock.Containers['mysql-server'] = [PSCustomObject]@{
        Id = 'production-id'; State = [PSCustomObject]@{ Running = $true }
    }
    $rootEnv = Join-Path $caseRoot '.env'
    $backendEnv = Join-Path $caseRoot 'backend/.env'
    $rootOriginal = "# root settings`r`nDB_HOST=old-host`r`nDB_PORT=3307`r`nDB_NAME=old-db`r`nDB_USER=root`r`nDB_PASSWORD=old-private-value`r`nFLASK_PORT=5000`r`nVITE_DEV_PORT=5173`r`nCUSTOM_VALUE=keep=literal`r`n"
    $backendOriginal = "# backend settings`nexport DB_HOST = localhost`nDB_PORT=3333`nDB_NAME=backend-old`nDB_USER=root`nDB_PASSWORD=another-private-value`nSQLALCHEMY_TRACK_MODIFICATIONS=false`n"
    Write-TestText $rootEnv $rootOriginal
    Write-TestText $backendEnv $backendOriginal
    $rootBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($rootEnv))
    $backendBytes = [Convert]::ToBase64String([IO.File]::ReadAllBytes($backendEnv))
    Invoke-TestAction 'configure' $caseRoot

    $expected = [ordered]@{ DB_HOST = '127.0.0.1'; DB_PORT = '3306'; DB_NAME = 'my_new_board_db'; DB_USER = 'loop_app'; DB_PASSWORD = $password }
    foreach ($file in @($rootEnv, $backendEnv)) {
        $text = [IO.File]::ReadAllText($file)
        foreach ($key in $expected.Keys) {
            $pattern = '(?m)^' + [regex]::Escape($key + '=' + $expected[$key]) + '$'
            Assert-Loop ([regex]::Matches($text, $pattern).Count -eq 1) ('DB setting not updated once: ' + $key)
        }
    }
    $rootText = [IO.File]::ReadAllText($rootEnv)
    $backendText = [IO.File]::ReadAllText($backendEnv)
    Assert-Loop ($rootText.Contains('# root settings') -and $rootText.Contains('CUSTOM_VALUE=keep=literal')) 'Root unrelated settings changed.'
    Assert-Loop ($rootText.Contains('FLASK_PORT=5000') -and $rootText.Contains('VITE_DEV_PORT=5173')) 'Web ports changed.'
    Assert-Loop ($backendText.Contains('# backend settings') -and $backendText.Contains('SQLALCHEMY_TRACK_MODIFICATIONS=false')) 'Backend unrelated settings changed.'
    $rootBackup = Join-Path $private 'repo-env.before'
    $backendBackup = Join-Path $private 'backend-env.before'
    Assert-Loop ([Convert]::ToBase64String([IO.File]::ReadAllBytes($rootBackup)) -eq $rootBytes) 'Root original backup differs.'
    Assert-Loop ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backendBackup)) -eq $backendBytes) 'Backend original backup differs.'
    Write-TestText $rootEnv ($rootText + "NEW_UNRELATED_VALUE=preserve-on-retry`n")
    Invoke-TestAction 'configure' $caseRoot
    Assert-Loop ([Convert]::ToBase64String([IO.File]::ReadAllBytes($rootBackup)) -eq $rootBytes) 'Configure retry overwrote original root backup.'
    Assert-Loop ([Convert]::ToBase64String([IO.File]::ReadAllBytes($backendBackup)) -eq $backendBytes) 'Configure retry overwrote original backend backup.'
    Assert-Loop ([IO.File]::ReadAllText($rootEnv).Contains('NEW_UNRELATED_VALUE=preserve-on-retry')) 'Configure retry removed unrelated setting.'
    $configuredState = Get-Content -LiteralPath (Join-Path $private 'state.json') -Raw | ConvertFrom-Json
    Assert-Loop $configuredState.Configured 'Configure did not mark completion.'
    Assert-Loop ($global:LoopDockerMock.Sql.Count -eq 0) 'Configure unexpectedly ran SQL.'
    Assert-NoContainerMutation
    $testCount++
    Write-Host 'PASS: configure preserves settings, ports and original backups on retry'

    Write-Host ('PASS: ' + $testCount + ' mock tests; no real Docker, MySQL or network calls')
}
finally {
    Remove-Item -LiteralPath Function:/docker -Force -ErrorAction SilentlyContinue
    Remove-Variable -Name LoopDockerMock -Scope Global -ErrorAction SilentlyContinue
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    $resolvedTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedTestRoot.StartsWith($resolvedTemp, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe temporary cleanup target.'
    }
    Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
}
