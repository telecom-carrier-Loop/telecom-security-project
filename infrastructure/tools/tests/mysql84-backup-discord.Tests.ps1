[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
$tool=(Resolve-Path (Join-Path $PSScriptRoot '../mysql84-backup-discord.ps1')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('loop-discord-tests-'+[guid]::NewGuid().ToString('N'))
$repo=Join-Path $testRoot 'fixture repo & space'
$backupRoot=Join-Path $repo '.secrets/backups/mysql84/pc2'
$scheduler=Join-Path $backupRoot 'scheduler'
$monitor=Join-Path $backupRoot 'discord-monitor'
$backup=Join-Path $backupRoot '20261022-222511-763-06f9b2'
$null=New-Item -ItemType Directory -Path $scheduler -Force
$null=New-Item -ItemType Directory -Path $backup -Force
$utf8=[Text.UTF8Encoding]::new($false)
function Write-Fixture([string]$Path,$Value) { [IO.File]::WriteAllText($Path,($Value|ConvertTo-Json -Depth 8),$utf8) }
function Assert-Test([bool]$Ok,[string]$Message) { if(-not $Ok){throw ('ASSERT: '+$Message)} }
function Step([string]$Action) { & $tool -RepositoryPath $repo -Action $Action }
function Expect-Failure([string]$Action,[string]$Pattern) {
    $message='';try { Step $Action } catch { $message=$_.Exception.Message }
    Assert-Test ($message -like ('*'+$Pattern+'*')) ('Expected '+$Pattern+'; got '+$message)
}
function Read-Monitor([string]$File) { Get-Content -LiteralPath (Join-Path $monitor $File) -Raw|ConvertFrom-Json }
function Set-Record([string]$Status='success',[int]$MinutesAgo=1) {
    $now=[DateTime]::UtcNow
    $record=[PSCustomObject]@{RunId='fixture';Status=$Status;StartedUtc=$now.AddMinutes(-$MinutesAgo-1).ToString('o');CompletedUtc=$now.AddMinutes(-$MinutesAgo).ToString('o');ExitCode=0;BackupDirectory=$backup;Log='never-read.log'}
    if($Status -eq 'failed'){$record.ExitCode=1}
    if($Status -eq 'running'){$record.CompletedUtc='';$record.ExitCode=$null}
    Write-Fixture (Join-Path $scheduler 'last-run.json') $record
    if($Status -eq 'success'){Write-Fixture (Join-Path $scheduler 'last-success.json') $record}
}
$global:DiscordMock=@{Messages=[Collections.Generic.List[string]]::new();Fail=$false;TaskState='Ready';TaskResult=0;TaskAge=1;Missing=$false;MonitorTask=$null;RegisterCount=0;Secret='https://discord.com/api/webhooks/12345/fixture_only_token'}
function global:Read-Host { param($Prompt,[switch]$AsSecureString) ConvertTo-SecureString $global:DiscordMock.Secret -AsPlainText -Force }
function global:Invoke-WebRequest {
    param($Uri,$Method,[switch]$UseBasicParsing,$MaximumRedirection,$TimeoutSec,$ContentType,$Body)
    $m=$global:DiscordMock
    if($m.Fail){throw ('Simulated HTTP failure at '+$m.Secret)}
    Assert-Test ($Uri -eq ($m.Secret+'?wait=true') -and $Method -eq 'Post' -and $MaximumRedirection -eq 0 -and $TimeoutSec -eq 15) 'Unsafe HTTP request.'
    $payload=[Text.Encoding]::UTF8.GetString($Body)|ConvertFrom-Json
    Assert-Test (@($payload.allowed_mentions.parse).Count -eq 0) 'Mentions were enabled.'
    Assert-Test (-not $payload.content.Contains($m.Secret) -and -not $payload.content.Contains('snapshot.sql')) 'Sensitive detail in message.'
    $m.Messages.Add($payload.content)
    [PSCustomObject]@{StatusCode=200;Content='{"id":"fixture-confirmed-message"}'}
}
function global:Get-ScheduledTask {
    [CmdletBinding()]param($TaskName,$TaskPath)
    if($TaskName -eq 'Loop-MySQL84-PC2-Backup-Discord-Monitor'){return $global:DiscordMock.MonitorTask}
    if($global:DiscordMock.Missing){throw 'Fixture task missing.'}
    [PSCustomObject]@{State=$global:DiscordMock.TaskState}
}
function global:Get-ScheduledTaskInfo { param($TaskName,$TaskPath) [PSCustomObject]@{LastTaskResult=$global:DiscordMock.TaskResult;LastRunTime=(Get-Date).AddMinutes(-$global:DiscordMock.TaskAge);NextRunTime=(Get-Date).AddMinutes(30)} }
function global:New-ScheduledTaskAction { param($Execute,$Argument,$WorkingDirectory) [PSCustomObject]@{Execute=$Execute;Argument=$Argument;WorkingDirectory=$WorkingDirectory} }
function global:New-ScheduledTaskTrigger {
    [CmdletBinding()]param([switch]$Once,$At,$RepetitionInterval,$RepetitionDuration)
    Assert-Test ($RepetitionInterval.TotalMinutes -eq 5 -and -not $PSBoundParameters.ContainsKey('RepetitionDuration')) 'Wrong repetition.'
    [PSCustomObject]@{At=$At}
}
function global:New-ScheduledTaskPrincipal { param($UserId,$LogonType,$RunLevel) [PSCustomObject]@{UserId=$UserId;LogonType=$LogonType;RunLevel=$RunLevel} }
function global:New-ScheduledTaskSettingsSet {
    param([switch]$StartWhenAvailable,$MultipleInstances,$ExecutionTimeLimit,[switch]$AllowStartIfOnBatteries,[switch]$DontStopIfGoingOnBatteries)
    Assert-Test ($StartWhenAvailable -and $MultipleInstances -eq 'IgnoreNew' -and $ExecutionTimeLimit.TotalMinutes -eq 2) 'Unsafe monitor settings.'
    [PSCustomObject]@{MultipleInstances=$MultipleInstances}
}
function global:Register-ScheduledTask {
    param($TaskName,$TaskPath,$Action,$Trigger,$Principal,$Settings,$Description)
    Assert-Test ($TaskName -eq 'Loop-MySQL84-PC2-Backup-Discord-Monitor') 'Existing backup task changed.'
    Assert-Test ($Principal.UserId -eq [Security.Principal.WindowsIdentity]::GetCurrent().User.Value -and $Principal.LogonType -eq 'Interactive' -and $Principal.RunLevel -eq 'Limited') 'Wrong Windows identity.'
    Assert-Test ($Action.Argument.Contains('-WindowStyle Hidden') -and $Action.Argument.Contains('-Action Check') -and $Action.Argument.Contains($monitor) -and -not $Action.Argument.Contains('webhooks/')) 'Unsafe task arguments.'
    $global:DiscordMock.RegisterCount++
    $global:DiscordMock.MonitorTask=[PSCustomObject]@{State='Ready'}
}
try {
    Write-Fixture (Join-Path $scheduler 'config.json') @{OwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;RepositoryPath=$repo;TaskName='Loop-MySQL84-PC2-Hourly-Backup'}
    Write-Fixture (Join-Path $backup 'manifest.json') @{fixture=$true}
    [IO.File]::WriteAllText((Join-Path $backup 'snapshot.sql'),'fixture SQL; never restored',$utf8)
    Set-Record
    Step SaveWebhook
    Assert-Test (-not ([IO.File]::ReadAllText((Join-Path $monitor 'webhook.clixml'))).Contains($global:DiscordMock.Secret)) 'Webhook stored as plaintext.'
    Expect-Failure Install '*'
    Step TestAlert
    Assert-Test ($global:DiscordMock.Messages.Count -eq 1 -and $global:DiscordMock.Messages[0].StartsWith('[TEST]')) 'No test delivery.'
    Step Install
    Assert-Test ($global:DiscordMock.RegisterCount -eq 1) 'Monitor was not registered.'
    Expect-Failure Install 'already exists'
    Expect-Failure SaveWebhook 'already configured'
    Step Check
    Assert-Test ($global:DiscordMock.Messages.Count -eq 1) 'Healthy initial check sent a message.'

    Set-Record failed
    Expect-Failure Check 'Backup health alert'
    Assert-Test ($global:DiscordMock.Messages.Count -eq 2 -and (Read-Monitor 'incident.json').Open) 'Failure not delivered.'
    Expect-Failure Check 'Backup health alert'
    Assert-Test ($global:DiscordMock.Messages.Count -eq 2) 'Duplicate was not suppressed.'
    Set-Record running
    $global:DiscordMock.TaskState='Running';$global:DiscordMock.TaskResult=267009
    Step Check
    Assert-Test ($global:DiscordMock.Messages.Count -eq 2 -and (Read-Monitor 'incident.json').Open) 'Recovery sent during retry/running task.'
    $global:DiscordMock.TaskState='Ready';$global:DiscordMock.TaskResult=0
    Set-Record
    Step Check
    Assert-Test ($global:DiscordMock.Messages.Count -eq 3 -and $global:DiscordMock.Messages[2].StartsWith('[RECOVERY]') -and -not (Read-Monitor 'incident.json').Open) 'Recovery not delivered.'
    Step Check
    Assert-Test ($global:DiscordMock.Messages.Count -eq 3) 'Recovery repeated.'

    Set-Record success 95
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'no-success-within-90-minutes') 'Stale backup not detected.'
    $record=Read-Monitor 'incident.json';$record.LastSentUtc=[DateTime]::UtcNow.AddMinutes(-61).ToString('o')
    Write-Fixture (Join-Path $monitor 'incident.json') $record
    $before=$global:DiscordMock.Messages.Count
    Expect-Failure Check 'Backup health alert'
    Assert-Test ($global:DiscordMock.Messages.Count -eq $before+1) 'Hourly reminder missing.'
    Set-Record
    Step Check

    Set-Record failed
    $global:DiscordMock.Fail=$true
    $before=[IO.File]::ReadAllText((Join-Path $monitor 'incident.json'))
    Expect-Failure Check 'Discord delivery failed'
    Assert-Test ((Read-Monitor 'last-check.json').Delivery -eq 'failed' -and [IO.File]::ReadAllText((Join-Path $monitor 'incident.json')) -ceq $before) 'Failed delivery consumed alert state.'
    $global:DiscordMock.Fail=$false
    Expect-Failure Check 'Backup health alert'
    Set-Record
    Step Check

    $global:DiscordMock.TaskState='Disabled'
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-task-not-ready') 'Disabled backup task ignored.'
    $global:DiscordMock.TaskState='Ready';$global:DiscordMock.TaskResult=1
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-task-exit-nonzero') 'Nonzero result ignored.'
    $global:DiscordMock.TaskResult=0;$global:DiscordMock.Missing=$true
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-task-unavailable') 'Missing task ignored.'
    $global:DiscordMock.Missing=$false
    Set-Record running 15
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-running-over-12-minutes') 'Stuck run ignored.'
    Set-Record
    [IO.File]::WriteAllText((Join-Path $scheduler 'last-run.json'),'{invalid JSON',$utf8)
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-run-record-invalid') 'Malformed record ignored.'
    Set-Record success -20
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-success-record-invalid') 'Future success accepted.'
    Set-Record
    [IO.File]::Move((Join-Path $backup 'snapshot.sql'),(Join-Path $backup 'snapshot.saved'))
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'last-backup-files-unavailable') 'Missing dump ignored.'
    [IO.File]::Move((Join-Path $backup 'snapshot.saved'),(Join-Path $backup 'snapshot.sql'))
    Step Check
    $global:DiscordMock.TaskState='Running';$global:DiscordMock.TaskAge=15
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'backup-running-over-12-minutes') 'Task bootstrap hang ignored.'
    $global:DiscordMock.TaskState='Ready';$global:DiscordMock.TaskAge=1
    Step Check
    [IO.File]::WriteAllText((Join-Path $monitor 'incident.json'),'{invalid JSON',$utf8)
    Expect-Failure Check 'Backup health alert'
    Assert-Test ((Read-Monitor 'last-check.json').Issues -contains 'monitor-incident-record-invalid') 'Corrupt incident prevented an alert.'
    Step Check
    $before=$global:DiscordMock.Messages.Count
    [IO.File]::AppendAllText((Join-Path $monitor 'mysql84-backup-discord.ps1'),'# changed',$utf8)
    Expect-Failure Check 'hash changed'
    Assert-Test ($global:DiscordMock.Messages.Count -eq $before) 'Changed installed worker was used.'
    Write-Host 'PASS: Discord monitor fixtures; DPAPI, task isolation, failure/stale/stuck/corrupt/missing detection, dedup/reminder/recovery, send retry and hash guard. No Docker, real tasks or external messages.'
}
finally {
    foreach($name in @('Read-Host','Invoke-WebRequest','Get-ScheduledTask','Get-ScheduledTaskInfo','New-ScheduledTaskAction','New-ScheduledTaskTrigger','New-ScheduledTaskPrincipal','New-ScheduledTaskSettingsSet','Register-ScheduledTask')) { Remove-Item -LiteralPath ('Function:global:'+ $name) -ErrorAction SilentlyContinue }
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\'
    if(-not $resolved.StartsWith($temporaryRoot,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'loop-discord-tests-*'){throw 'Unsafe fixture cleanup path.'}
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
