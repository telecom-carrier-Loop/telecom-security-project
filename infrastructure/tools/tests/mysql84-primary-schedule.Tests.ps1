[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$schedule=(Resolve-Path (Join-Path $PSScriptRoot '../mysql84-backup-schedule.ps1')).Path
$monitor=(Resolve-Path (Join-Path $PSScriptRoot '../mysql84-backup-discord.ps1')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('loop-primary-schedule-tests-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $testRoot 'fixture repo & space'
$replica=Join-Path $repo '.secrets/backups/mysql84/pc2'
$primary=Join-Path $repo '.secrets/backups/mysql84/pc2-primary'
$utf8=[Text.UTF8Encoding]::new($false)
$owner=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
function Assert-Test([bool]$Ok,[string]$Message) { if(-not $Ok){throw ('ASSERT: '+$Message)} }
function Write-Json([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8),$utf8) }
function Step([string]$Tool,[string]$Action) { & $Tool -RepositoryPath $repo -SourceRole Primary -Action $Action -ErrorAction Stop }
function Expect-Failure([string]$Tool,[string]$Action) { $failed=$false;try{Step $Tool $Action}catch{$failed=$true};Assert-Test $failed ('Unexpected success: '+$Action) }
$backupName='Loop-MySQL84-PC2-Primary-Hourly-Backup'
$monitorName='Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor'
$null=New-Item -ItemType Directory -Path (Join-Path $replica 'credentials'),(Join-Path $replica 'discord-monitor') -Force
[Management.Automation.PSCredential]::new('loop_backup',(ConvertTo-SecureString 'DummyBackupOnly9!' -AsPlainText -Force)) | Export-Clixml (Join-Path $replica 'credentials/loop_backup.clixml')
[Management.Automation.PSCredential]::new('discord-webhook',(ConvertTo-SecureString 'https://discord.com/api/webhooks/12345/fixture_only_token' -AsPlainText -Force)) | Export-Clixml (Join-Path $replica 'discord-monitor/webhook.clixml')
Write-Json (Join-Path $replica 'latest.json') @{Stage='restore-verified';Directory='fixture-verified-replica'}
Write-Json (Join-Path $replica 'discord-monitor/config.json') @{OwnerSid=$owner;RepositoryPath=$repo}
$latestBefore=[IO.File]::ReadAllText((Join-Path $replica 'latest.json'))
$webhookBefore=(Get-FileHash (Join-Path $replica 'discord-monitor/webhook.clixml')).Hash
$dummyDocker=Join-Path $repo 'docker.exe'
[IO.File]::WriteAllText($dummyDocker,'fixture, never executed')
$fakeBackup=Join-Path $repo 'fake-backup.ps1'
[IO.File]::WriteAllText($fakeBackup,@'
param($RepositoryPath,$Action,$SourceRole)
if($Action -ne 'BackupSaved' -or $SourceRole -ne 'Primary'){throw 'Wrong backup role/action'}
$root=Join-Path $RepositoryPath '.secrets/backups/mysql84/pc2-primary'
$directory=Join-Path $root ([guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $directory
[IO.File]::WriteAllText((Join-Path $directory 'manifest.json'),'{}')
[IO.File]::WriteAllText((Join-Path $directory 'snapshot.sql'),'fixture; never restored')
[IO.File]::WriteAllText((Join-Path $root 'latest.json'),(@{Stage='backup-ready';SourceRole='Primary';Directory=$directory}|ConvertTo-Json))
exit 0
'@,$utf8)
$global:PrimaryTasks=@{}
$global:PrimaryMessages=[Collections.Generic.List[string]]::new()
foreach($name in @('Loop-MySQL84-PC2-Hourly-Backup','Loop-MySQL84-PC2-Backup-Discord-Monitor')){$global:PrimaryTasks[$name]=[pscustomobject]@{State='Ready';Xml='';Principal=[pscustomobject]@{RunLevel='Limited'};Result=0}}
function global:Get-Command { param($Name,$CommandType,$ErrorAction) [pscustomobject]@{Source=$dummyDocker} }
function global:Get-ScheduledTask { [CmdletBinding()]param($TaskName,$TaskPath) if($global:PrimaryTasks.ContainsKey($TaskName)){$global:PrimaryTasks[$TaskName]} }
function global:Get-ScheduledTaskInfo { param($TaskName,$TaskPath) [pscustomobject]@{LastTaskResult=$global:PrimaryTasks[$TaskName].Result;LastRunTime=(Get-Date).AddMinutes(-1);NextRunTime=(Get-Date).AddHours(1)} }
function global:New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) [pscustomobject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory} }
function global:New-ScheduledTaskTrigger { [CmdletBinding()]param([switch]$Once,$At,$RepetitionInterval,$RepetitionDuration) Assert-Test (-not $PSBoundParameters.ContainsKey('RepetitionDuration')) 'Expiring trigger';[pscustomobject]@{Interval=$RepetitionInterval} }
function global:New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) [pscustomobject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
function global:New-ScheduledTaskSettingsSet { param([switch]$Disable,[switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries) [pscustomobject]@{Disable=$Disable;ExecutionTimeLimit=$ExecutionTimeLimit;StartWhenAvailable=$StartWhenAvailable;MultipleInstances=$MultipleInstances} }
function global:Register-ScheduledTask {
    param($TaskName,$TaskPath,$Action,$Trigger,$Principal,$Settings,$Description)
    Assert-Test ($TaskName -in @($backupName,$monitorName) -and $Settings.Disable) 'Existing task changed or new task not disabled'
    Assert-Test ($Principal.UserId -eq $owner -and $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited') 'Wrong task identity'
    Assert-Test ($Action.Argument.Contains('-SourceRole Primary') -and $Action.Argument.Contains('-WindowStyle Hidden')) 'Wrong role/action arguments'
    $command=[Security.SecurityElement]::Escape($Action.Execute)
    $arguments=[Security.SecurityElement]::Escape($Action.Argument)
    $working=[Security.SecurityElement]::Escape($Action.WorkingDirectory)
    $interval=[Xml.XmlConvert]::ToString($Trigger.Interval)
    $limit=[Xml.XmlConvert]::ToString($Settings.ExecutionTimeLimit)
    $xml=@"
<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>$owner</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals><Actions><Exec><Command>$command</Command><Arguments>$arguments</Arguments><WorkingDirectory>$working</WorkingDirectory></Exec></Actions><Triggers><TimeTrigger><Repetition><Interval>$interval</Interval></Repetition></TimeTrigger></Triggers><Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><ExecutionTimeLimit>$limit</ExecutionTimeLimit><StartWhenAvailable>true</StartWhenAvailable></Settings></Task>
"@
    $global:PrimaryTasks[$TaskName]=[pscustomobject]@{State='Disabled';Xml=$xml;Principal=[pscustomobject]@{RunLevel='Limited'};Result=267011}
}
function global:Export-ScheduledTask { param($TaskName,$TaskPath) $global:PrimaryTasks[$TaskName].Xml }
function global:Enable-ScheduledTask { param($TaskName,$TaskPath) Assert-Test ($TaskName -in @($backupName,$monitorName)) 'Replica task touched';$global:PrimaryTasks[$TaskName].State='Ready' }
function global:Invoke-WebRequest {
    param($Uri,$Method,[switch]$UseBasicParsing,$MaximumRedirection,$TimeoutSec,$ContentType,$Body)
    Assert-Test ($Uri -eq 'https://discord.com/api/webhooks/12345/fixture_only_token?wait=true') 'Unexpected webhook'
    $payload=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    Assert-Test ($payload.content -notmatch 'fixture_only_token' -and @($payload.allowed_mentions.parse).Count -eq 0) 'Secret/mention leak'
    $global:PrimaryMessages.Add($payload.content)
    [pscustomobject]@{StatusCode=200;Content='{"id":"fixture-only-confirmed"}'}
}
try {
    & $schedule -RepositoryPath $repo -SourceRole Primary -Action Prepare -BackupToolPath $fakeBackup
    Assert-Test ($global:PrimaryTasks[$backupName].State -eq 'Disabled') 'Backup prepared enabled'
    foreach($action in @('Run','Test','Repair','Install')){Expect-Failure $schedule $action}
    Assert-Test ($global:PrimaryTasks[$backupName].State -eq 'Disabled') 'Pending backup activation escaped guard'
    Step $monitor Prepare
    Assert-Test ($global:PrimaryTasks[$monitorName].State -eq 'Disabled' -and $global:PrimaryMessages.Count -eq 0) 'Prepare sent a message or enabled monitor'
    Expect-Failure $monitor Check
    Expect-Failure $monitor Install
    $originalXml=$global:PrimaryTasks[$monitorName].Xml
    $global:PrimaryTasks[$monitorName].Xml=$originalXml.Replace('-SourceRole Primary','-SourceRole Replica')
    Expect-Failure $monitor Prepare
    $global:PrimaryTasks[$monitorName].Xml=$originalXml
    Step $monitor TestAlert
    Assert-Test ($global:PrimaryMessages.Count -eq 1 -and $global:PrimaryMessages[0].Contains('Primary')) 'No role-labelled test receipt'
    Expect-Failure $monitor Install

    # Stand-in for a manually verified Primary backup/restore; no real DB state is changed.
    Write-Json (Join-Path $primary 'latest.json') @{Stage='restore-verified';SourceRole='Replica';Directory='wrong-role'}
    Expect-Failure $schedule Install
    Write-Json (Join-Path $primary 'latest.json') @{Stage='restore-verified';SourceRole='Primary';Directory='fixture-verified-primary'}
    Step $schedule Install
    Assert-Test ($global:PrimaryTasks[$backupName].State -eq 'Ready') 'Verified Primary schedule did not activate'
    Expect-Failure $monitor Install
    Step $schedule Run
    $global:PrimaryTasks[$backupName].Result=0
    $successPath=Join-Path $primary 'scheduler/last-success.json'
    $success=Get-Content $successPath -Raw|ConvertFrom-Json
    Assert-Test ($success.SourceRole -eq 'Primary' -and $success.Status -eq 'success') 'Worker did not use Primary mode'
    Step $monitor Install
    Assert-Test ($global:PrimaryTasks[$monitorName].State -eq 'Ready') 'Healthy Primary monitor did not activate'
    Step $monitor Check
    Assert-Test ($global:PrimaryMessages.Count -eq 1) 'Healthy check sent an alert'
    $success.SourceRole='Replica';Write-Json $successPath $success
    Expect-Failure $monitor Check
    Assert-Test ($global:PrimaryMessages.Count -eq 2 -and $global:PrimaryMessages[1].Contains('Primary')) 'Wrong-role record was accepted'
    $success.SourceRole='Primary';Write-Json $successPath $success
    Step $monitor Check
    Assert-Test ($global:PrimaryMessages.Count -eq 3 -and $global:PrimaryMessages[2].StartsWith('[RECOVERY]')) 'Primary recovery missing'
    Assert-Test ([IO.File]::ReadAllText((Join-Path $replica 'latest.json')) -ceq $latestBefore -and (Get-FileHash (Join-Path $replica 'discord-monitor/webhook.clixml')).Hash -eq $webhookBefore) 'Replica files changed'
    Assert-Test ($global:PrimaryTasks['Loop-MySQL84-PC2-Hourly-Backup'].State -eq 'Ready' -and $global:PrimaryTasks['Loop-MySQL84-PC2-Backup-Discord-Monitor'].State -eq 'Ready') 'Replica task disabled'
    Write-Host 'PASS: Primary disabled preparation, pending Run/Test/Repair/activation guards, task tamper, verified activation, role-labelled records/messages, wrong-role alert/recovery and Replica isolation. No real tasks, DB or messages.'
}
finally {
    foreach($name in @('Get-Command','Get-ScheduledTask','Get-ScheduledTaskInfo','New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask','Export-ScheduledTask','Enable-ScheduledTask','Invoke-WebRequest')){Remove-Item -LiteralPath ('Function:\'+$name) -ErrorAction SilentlyContinue}
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'loop-primary-schedule-tests-*'){throw 'Unsafe fixture cleanup path'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
