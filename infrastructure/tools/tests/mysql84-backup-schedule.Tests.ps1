[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tool=(Resolve-Path (Join-Path $PSScriptRoot '../mysql84-backup-schedule.ps1')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('loop-schedule-tests-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$utf8=[Text.UTF8Encoding]::new($false)
function Assert-Test([bool]$Ok,[string]$Message) { if(-not $Ok) { throw ('ASSERT: '+$Message) } }
function New-Case([string]$Name) {
    $path=Join-Path $testRoot ($Name+' repo & space')
    $root=Join-Path $path '.secrets/backups/mysql84/pc2'
    $null=New-Item -ItemType Directory -Path (Join-Path $root 'credentials') -Force
    [IO.File]::WriteAllText((Join-Path $root 'latest.json'),(@{Stage='restore-verified';Directory=(Join-Path $root 'previous')}|ConvertTo-Json),$utf8)
    [Management.Automation.PSCredential]::new('loop_backup',(ConvertTo-SecureString 'fake-only-password' -AsPlainText -Force)) | Export-Clixml -LiteralPath (Join-Path $root 'credentials/loop_backup.clixml')
    $dockerPath=Join-Path $path 'docker.exe'
    [IO.File]::WriteAllText($dockerPath,'not executable; fixture never calls Docker',$utf8)
    $backup=Join-Path $path 'fixture-backup.ps1'
    [IO.File]::WriteAllText($backup,@'
param($RepositoryPath,$Action)
$ErrorActionPreference='Stop'
if($Action -ne 'BackupSaved') { throw 'Wrong backup action.' }
$root=Join-Path $RepositoryPath '.secrets/backups/mysql84/pc2'
$mode=Get-Content -LiteralPath (Join-Path $RepositoryPath 'mode.txt') -Raw
if($mode -eq 'fail') { Write-Output 'Fixture backup failed';exit 7 }
if($mode -eq 'noop') { exit 0 }
$directory=Join-Path $root ((Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6))
$null=New-Item -ItemType Directory -Path $directory
[IO.File]::WriteAllText((Join-Path $directory 'manifest.json'),'{}')
[IO.File]::WriteAllText((Join-Path $root 'latest.json'),(@{Stage='backup-ready';Directory=$directory}|ConvertTo-Json))
Write-Output 'Fixture BackupSaved completed'
exit 0
'@,$utf8)
    [IO.File]::WriteAllText((Join-Path $path 'mode.txt'),'success',$utf8)
    $global:ScheduleMock=@{Repo=$path;DockerPath=$dockerPath;Task=$null;Xml='';RegisterCalls=0;StartCalls=0;LastResult=267011;LastRunTime=[DateTime]::MinValue;NoStart=$false;BootstrapFailure=$false;Trigger=$null;Principal=$null;Settings=$null;Action=$null}
    $path
}
function Run-Step([string]$Path,[string]$Action) { & $tool -RepositoryPath $Path -Action $Action -BackupToolPath (Join-Path $Path 'fixture-backup.ps1') }
function Expect-Failure([string]$Path,[string]$Action,[string]$Expected) {
    $message='';try { Run-Step $Path $Action } catch { $message=$_.Exception.Message }
    Assert-Test ($message -like ('*'+$Expected+'*')) ('Expected '+$Expected+'; got '+$message)
}
function Read-Record([string]$Path,[string]$File='last-run.json') { Get-Content -LiteralPath (Join-Path $Path ('.secrets/backups/mysql84/pc2/scheduler/'+$File)) -Raw | ConvertFrom-Json }
function global:Get-Command { param($Name,$CommandType,$ErrorAction) [PSCustomObject]@{Source=$global:ScheduleMock.DockerPath} }
function global:Get-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) $global:ScheduleMock.Task }
function global:Get-ScheduledTaskInfo { param($TaskName,$TaskPath) [PSCustomObject]@{LastTaskResult=$global:ScheduleMock.LastResult;LastRunTime=$global:ScheduleMock.LastRunTime;NextRunTime=(Get-Date).AddHours(1)} }
function global:New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) $global:ScheduleMock.Action=[PSCustomObject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory};$global:ScheduleMock.Action }
function global:New-ScheduledTaskTrigger { [CmdletBinding()]param([switch]$Once,$At,$RepetitionInterval,$RepetitionDuration)
    Assert-Test ($Once -and -not $PSBoundParameters.ContainsKey('RepetitionDuration')) 'Duration was specified; repetition could expire.'
    $global:ScheduleMock.Trigger=[PSCustomObject]@{Interval=$RepetitionInterval;At=$At};$global:ScheduleMock.Trigger
}
function global:New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) $global:ScheduleMock.Principal=[PSCustomObject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel};$global:ScheduleMock.Principal }
function global:New-ScheduledTaskSettingsSet { param([switch]$Disable,[switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)
    $global:ScheduleMock.Settings=[PSCustomObject]@{Disable=$Disable;StartWhenAvailable=$StartWhenAvailable;MultipleInstances=$MultipleInstances;ExecutionTimeLimit=$ExecutionTimeLimit};$global:ScheduleMock.Settings
}
function global:Register-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath,$Action,$Trigger,$Principal,$Settings,$Description)
    $m=$global:ScheduleMock;$m.RegisterCalls++
    Assert-Test ($Principal.UserId -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited') 'Wrong account/logon/run level.'
    Assert-Test ($Settings.Disable -and $Settings.StartWhenAvailable -and $Settings.MultipleInstances -eq 'IgnoreNew' -and $Settings.ExecutionTimeLimit.TotalMinutes -eq 10) 'Unsafe task settings.'
    $command=[Security.SecurityElement]::Escape($Action.Execute)
    $arguments=[Security.SecurityElement]::Escape($Action.Argument)
    $working=[Security.SecurityElement]::Escape($Action.WorkingDirectory)
    $interval=[Xml.XmlConvert]::ToString($Trigger.Interval)
    $m.Xml=@"
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>$($Principal.UserId)</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Actions><Exec><Command>$command</Command><Arguments>$arguments</Arguments><WorkingDirectory>$working</WorkingDirectory></Exec></Actions><Triggers><TimeTrigger><Repetition><Interval>$interval</Interval></Repetition></TimeTrigger></Triggers><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>PT10M</ExecutionTimeLimit><StartWhenAvailable>true</StartWhenAvailable></Settings></Task>
"@
    $m.Task=[PSCustomObject]@{State='Disabled'}
}
function global:Export-ScheduledTask { param($TaskName,$TaskPath) $global:ScheduleMock.Xml }
function global:Enable-ScheduledTask { param($TaskName,$TaskPath) $global:ScheduleMock.Task.State='Ready' }
function global:Start-Sleep { param($Seconds) }
function global:Start-ScheduledTask { param($TaskName,$TaskPath)
    $m=$global:ScheduleMock;$m.StartCalls++
    if($m.NoStart) { return }
    $m.LastRunTime=Get-Date
    if($m.BootstrapFailure) { $m.LastResult=1;return }
    $m.Task.State='Running'
    # Execute the exact registered command line as a real hidden PS 5.1 child, with fake backup only.
    $process=Start-Process -FilePath $m.Action.Execute -ArgumentList $m.Action.Argument -WorkingDirectory $m.Action.WorkingDirectory -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput (Join-Path $m.Repo 'worker.stdout') -RedirectStandardError (Join-Path $m.Repo 'worker.stderr')
    $m.LastResult=$process.ExitCode;$m.Task.State='Ready'
    if ($process.ExitCode -ne 0 -and -not (Test-Path -LiteralPath (Join-Path $m.Repo '.secrets/backups/mysql84/pc2/scheduler/last-run.json'))) {
        throw ('Fixture worker bootstrap failed: ' + [IO.File]::ReadAllText((Join-Path $m.Repo 'worker.stderr')))
    }
}
try {
    $p=New-Case 'success';Run-Step $p Install
    $m=$global:ScheduleMock
    Assert-Test ($m.Trigger.Interval.TotalHours -eq 1 -and $m.Task.State -eq 'Ready') 'Hourly task was not enabled.'
    Assert-Test ($m.Trigger.At -gt (Get-Date).AddMinutes(59) -and $m.Trigger.At -lt (Get-Date).AddMinutes(61)) 'First scheduled run is not one hour after installation.'
    Assert-Test ($m.Action.Argument.Contains('-WindowStyle Hidden') -and $m.Action.Argument.Contains('-Action Run') -and -not $m.Action.Argument.Contains('password')) 'Unsafe task arguments.'
    $scheduler=Join-Path $p '.secrets/backups/mysql84/pc2/scheduler'
    Assert-Test ($m.Action.Argument.Contains($scheduler) -and -not $m.Action.Argument.Contains($tool)) 'Task depends on temporary/source location.'
    Run-Step $p Test
    Assert-Test ($m.LastResult -eq 0 -and (Read-Record $p).Status -eq 'success' -and (Read-Record $p 'last-success.json').BackupDirectory -ne '') 'Real worker command line did not create a new backup.'
    $configBefore=[IO.File]::ReadAllText((Join-Path $scheduler 'config.json'))
    Run-Step $p Install
    Assert-Test ($m.RegisterCalls -eq 1 -and [IO.File]::ReadAllText((Join-Path $scheduler 'config.json')) -ceq $configBefore) 'Repeated install overwrote tools/task.'
    Write-Host 'PASS: hourly indefinite interactive/limited definition and real hidden PS5 worker command line with spaces/ampersand'

    $successBefore=[IO.File]::ReadAllText((Join-Path $scheduler 'last-success.json'))
    [IO.File]::WriteAllText((Join-Path $p 'mode.txt'),'fail')
    Expect-Failure $p Test 'Scheduled backup failed'
    Assert-Test ($m.LastResult -ne 0 -and (Read-Record $p).Status -eq 'failed') 'Worker failure returned success.'
    Assert-Test ([IO.File]::ReadAllText((Join-Path $scheduler 'last-success.json')) -ceq $successBefore) 'Failure erased last known success.'
    [IO.File]::WriteAllText((Join-Path $p 'mode.txt'),'noop')
    Expect-Failure $p Test 'Scheduled backup failed'
    Assert-Test ((Read-Record $p).Status -eq 'failed') 'Exit zero without a new backup claimed success.'
    $m.NoStart=$true
    Expect-Failure $p Test 'within 90 seconds'
    Write-Host 'PASS: task failure/nonzero exit/no new backup/stale results cannot claim success; prior success retained'

    $m.NoStart=$false
    $m.BootstrapFailure=$true
    Expect-Failure $p Test 'before completion was recorded'
    $m.BootstrapFailure=$false
    foreach ($change in @(@('InteractiveToken','S4U'),@('LeastPrivilege','HighestAvailable'),@('PT1H','PT30M'),@('</Interval>','</Interval><Duration>P1D</Duration>'),@('-Action Run','-Action RestoreTest'))) {
        $original=$m.Xml;$m.Xml=$original.Replace($change[0],$change[1]);$started=$m.StartCalls
        Expect-Failure $p Test 'Registered task differs'
        Assert-Test ($m.StartCalls -eq $started) 'Modified task was started.'
        $m.Xml=$original
    }
    $held=[IO.File]::Open((Join-Path $scheduler 'run.lock'),'OpenOrCreate','ReadWrite','None')
    try { Expect-Failure $p Run 'Another scheduled worker' } finally { $held.Dispose() }
    [IO.File]::AppendAllText((Join-Path $scheduler 'mysql84-backup.ps1'),'# changed')
    Expect-Failure $p Test 'tool hash changed'
    Write-Host 'PASS: account/logon/privilege/interval/duration/action tampering, tool changes and overlapping workers rejected'

    $p=New-Case 'not-verified';$root=Join-Path $p '.secrets/backups/mysql84/pc2'
    [IO.File]::WriteAllText((Join-Path $root 'latest.json'),(@{Stage='backup-ready';Directory='fixture'}|ConvertTo-Json))
    Expect-Failure $p Install 'isolated restore test'
    Assert-Test ($global:ScheduleMock.RegisterCalls -eq 0) 'Unverified backup installed a task.'
    $p=New-Case 'foreign-task';$global:ScheduleMock.Task=[PSCustomObject]@{State='Ready'}
    Expect-Failure $p Install 'will not be replaced'
    Assert-Test ($global:ScheduleMock.RegisterCalls -eq 0) 'Foreign task overwritten.'
    $p=New-Case 'wrong-owner-credential';$root=Join-Path $p '.secrets/backups/mysql84/pc2'
    [Management.Automation.PSCredential]::new('root',(ConvertTo-SecureString 'fake' -AsPlainText -Force)) | Export-Clixml -LiteralPath (Join-Path $root 'credentials/loop_backup.clixml')
    Expect-Failure $p Install 'encrypted loop_backup'
    Assert-Test ($global:ScheduleMock.RegisterCalls -eq 0) 'Root credential installed a task.'
    Write-Host 'All schedule tests passed. Task Scheduler registration and Docker/MySQL simulated; worker PS5 command line executed for real.'
}
finally {
    foreach ($name in @('Get-Command','Get-ScheduledTask','Get-ScheduledTaskInfo','New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask','Export-ScheduledTask','Enable-ScheduledTask','Start-Sleep','Start-ScheduledTask')) { Remove-Item ('Function:\'+$name) -ErrorAction SilentlyContinue }
    Remove-Variable ScheduleMock -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'loop-schedule-tests-*') { throw 'Unsafe temporary cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
