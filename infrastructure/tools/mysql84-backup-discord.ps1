[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RepositoryPath,
    [ValidateSet('SaveWebhook', 'TestAlert', 'Check', 'Install', 'Status')][string]$Action = 'Status'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This monitor requires Windows and the original PC2 Windows user.' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$backupRoot = Join-Path $repo '.secrets/backups/mysql84/pc2'
$scheduler = Join-Path $backupRoot 'scheduler'
$root = Join-Path $backupRoot 'discord-monitor'
$configFile = Join-Path $root 'config.json'
$credentialFile = Join-Path $root 'webhook.clixml'
$workerFile = Join-Path $root 'mysql84-backup-discord.ps1'
$reportFile = Join-Path $root 'last-check.json'
$incidentFile = Join-Path $root 'incident.json'
$receiptFile = Join-Path $root 'test-delivery.json'
$taskName = 'Loop-MySQL84-PC2-Backup-Discord-Monitor'
$backupTaskName = 'Loop-MySQL84-PC2-Hourly-Backup'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$utf8 = [Text.UTF8Encoding]::new($false)

function Write-MonitorJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), $utf8)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function Read-MonitorJson([string]$Path) { Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
function Assert-WebhookUrl([string]$Url) {
    if ($Url -cnotmatch '^https://discord\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+/?$') {
        throw 'Expected a standard HTTPS discord.com webhook URL without query parameters. The URL was not displayed.'
    }
}
function Read-MonitorConfig {
    $value = Read-MonitorJson $configFile
    if ($value.Format -ne 'loop-mysql84-discord-v1' -or $value.OwnerSid -ne $sid -or $value.RepositoryPath -ne $repo -or
        $value.StaleMinutes -ne 90 -or $value.RunningMinutes -ne 12 -or $value.ReminderMinutes -ne 60) { throw 'Monitor configuration changed or belongs to another user.' }
    if ((Get-FileHash -LiteralPath $workerFile).Hash -ine $value.WorkerSha256) { throw 'Installed monitor hash changed. No message or task update was attempted.' }
    $value
}
function Get-MonitorArguments {
    '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $workerFile + '" -RepositoryPath "' + $repo + '" -Action Check'
}
function Send-MonitorMessage([string]$Content) {
    $credential = $null; $url = $null
    try {
        $credential = Import-Clixml -LiteralPath $credentialFile
        if ($credential -isnot [Management.Automation.PSCredential] -or $credential.UserName -cne 'discord-webhook') { throw 'Invalid stored webhook credential.' }
        $url = $credential.GetNetworkCredential().Password
        Assert-WebhookUrl $url
        $body = @{content=$Content; allowed_mentions=@{parse=@()}} | ConvertTo-Json -Depth 5 -Compress
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
            # wait=true requires Discord to confirm a saved message; never follow redirects with the token.
            $response = Invoke-WebRequest -Uri ($url.TrimEnd('/') + '?wait=true') -Method Post -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 15 -ContentType 'application/json; charset=utf-8' -Body ($utf8.GetBytes($body))
            if ($response.StatusCode -ne 200) { throw 'Discord did not confirm the message.' }
            $message = $response.Content | ConvertFrom-Json
            if (-not $message.id) { throw 'Discord did not return a message ID.' }
        }
        finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
    }
    catch {
        # Native HTTP exceptions can contain the token URL or response body. Do not rethrow them.
        $Error.Clear()
        throw 'Discord delivery failed. Check Internet access and the webhook in Discord; the secret URL and HTTP details were suppressed. Check retries on its next run.'
    }
    finally { $credential=$null; $url=$null }
}
function Read-UtcTime([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { throw 'Missing timestamp.' }
    [DateTimeOffset]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture).UtcDateTime
}
function Get-BackupHealth {
    $now = [DateTime]::UtcNow
    $issues = [Collections.Generic.List[string]]::new()
    $pending = $false; $successUtc = ''
    try {
        $task = Get-ScheduledTask -TaskName $backupTaskName -TaskPath '\' -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $backupTaskName -TaskPath '\' -ErrorAction Stop
        if ([string]$task.State -notin @('Ready','Running')) { $issues.Add('backup-task-not-ready') }
        if ([string]$task.State -eq 'Running') {
            $pending=$true
            if (($now-$info.LastRunTime.ToUniversalTime()).TotalMinutes -gt $config.RunningMinutes) { $issues.Add('backup-running-over-12-minutes') }
        }
        elseif ($info.LastTaskResult -ne 0) { $issues.Add('backup-task-exit-nonzero') }
    }
    catch { $issues.Add('backup-task-unavailable') }
    try {
        $last = Read-MonitorJson (Join-Path $scheduler 'last-run.json')
        $started = Read-UtcTime $last.StartedUtc
        if ($started -gt $now.AddMinutes(5)) { throw 'Future timestamp.' }
        switch ($last.Status) {
            'failed' { $issues.Add('backup-failed') }
            'running' {
                $pending=$true
                if (($now-$started).TotalMinutes -gt $config.RunningMinutes) { $issues.Add('backup-running-over-12-minutes') }
            }
            'success' {
                $completed = Read-UtcTime $last.CompletedUtc
                if ($completed -lt $started -or $completed -gt $now.AddMinutes(5) -or $last.ExitCode -ne 0) { throw 'Invalid completion record.' }
            }
            default { throw 'Unknown backup status.' }
        }
    }
    catch { $issues.Add('backup-run-record-invalid') }
    try {
        $success = Read-MonitorJson (Join-Path $scheduler 'last-success.json')
        $completed = Read-UtcTime $success.CompletedUtc
        $started = Read-UtcTime $success.StartedUtc
        $successUtc = $completed.ToString('o')
        if ($success.Status -ne 'success' -or $success.ExitCode -ne 0 -or $completed -lt $started -or $completed -gt $now.AddMinutes(5)) { throw 'Invalid success record.' }
        if (($now-$completed).TotalMinutes -gt $config.StaleMinutes) { $issues.Add('no-success-within-90-minutes') }
        if ((Split-Path -Path $success.BackupDirectory -Parent) -ne $backupRoot -or
            -not (Test-Path -LiteralPath (Join-Path $success.BackupDirectory 'manifest.json') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $success.BackupDirectory 'snapshot.sql') -PathType Leaf)) { $issues.Add('last-backup-files-unavailable') }
    }
    catch { $issues.Add('backup-success-record-invalid') }
    $status='healthy'
    if ($issues.Count -gt 0) { $status='alert' } elseif ($pending) { $status='pending' }
    [PSCustomObject]@{CheckedUtc=$now.ToString('o'); Status=$status; Issues=@($issues.ToArray() | Sort-Object -Unique); LastSuccessUtc=$successUtc; Delivery='not-needed'}
}

if ($Action -eq 'SaveWebhook') {
    # Reuse the existing installation's Windows identity; never read a DB password.
    $backupConfig = Read-MonitorJson (Join-Path $scheduler 'config.json')
    if ($backupConfig.OwnerSid -ne $sid -or $backupConfig.RepositoryPath -ne $repo -or $backupConfig.TaskName -ne $backupTaskName) { throw 'Use the original PC2 Windows backup user and repository.' }
    if (Test-Path -LiteralPath $configFile) { throw 'Monitor already configured. Do not overwrite its installed worker or credentials.' }
    $null = New-Item -ItemType Directory -Path $root -Force
    if (((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Monitor directory cannot be a reparse point.' }
    $acl=Get-Acl -LiteralPath $root
    $owner=[Security.Principal.SecurityIdentifier]::new($sid)
    $acl.SetOwner($owner); $acl.SetAccessRuleProtection($true,$false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($identity in @($owner,[Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit, ObjectInherit','None','Allow'))
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    $secret = Read-Host 'Paste the Discord webhook URL (hidden; do not send it in chat)' -AsSecureString
    $credential=[Management.Automation.PSCredential]::new('discord-webhook',$secret)
    try { Assert-WebhookUrl ($credential.GetNetworkCredential().Password); $credential | Export-Clixml -LiteralPath $credentialFile }
    finally { $credential=$null; $secret=$null }
    Copy-Item -LiteralPath $PSCommandPath -Destination $workerFile
    Write-MonitorJson $configFile ([PSCustomObject]@{Format='loop-mysql84-discord-v1'; OwnerSid=$sid; RepositoryPath=$repo; WorkerSha256=(Get-FileHash -LiteralPath $workerFile).Hash; StaleMinutes=90; RunningMinutes=12; ReminderMinutes=60})
    Write-Host 'PASS: webhook encrypted for this Windows user and computer; independent monitor worker saved. No message was sent.'
    return
}
$config=Read-MonitorConfig
if ($Action -eq 'TestAlert') {
    Send-MonitorMessage ('[TEST] PC2 MySQL backup Discord delivery test. No backup failure, restore, DB change or recovery was triggered. UTC=' + [DateTime]::UtcNow.ToString('o'))
    Write-MonitorJson $receiptFile ([PSCustomObject]@{DeliveredUtc=[DateTime]::UtcNow.ToString('o'); Kind='test-only'})
    Write-Host 'PASS: Discord confirmed the TEST message. Verify it in the selected channel.'
    return
}
if ($Action -eq 'Install') {
    $receipt=Read-MonitorJson $receiptFile
    $tested=Read-UtcTime $receipt.DeliveredUtc
    if ($receipt.Kind -ne 'test-only' -or $tested -lt [DateTime]::UtcNow.AddDays(-1) -or $tested -gt [DateTime]::UtcNow.AddMinutes(5)) { throw 'Run TestAlert successfully before installing the monitor.' }
    if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Monitor task already exists. Run Status; no task was replaced.' }
    $taskAction=New-ScheduledTaskAction -Execute $powershell -Argument (Get-MonitorArguments) -WorkingDirectory $repo
    $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5)
    $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Read-only backup record monitoring and Discord alerts. No MySQL or backup task changes.'
    Write-Host 'PASS: independent Discord monitor scheduled every 5 minutes for this logged-on Windows user. Existing hourly backup unchanged.'
    return
}
if ($Action -eq 'Status') {
    $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        $info=Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
        Write-Host ('Monitor task: '+$taskName+'; state='+$task.State+'; result='+$info.LastTaskResult+'; next='+$info.NextRunTime)
    } else { Write-Host 'Monitor task not installed.' }
    if (Test-Path -LiteralPath $reportFile) { Read-MonitorJson $reportFile | Format-List CheckedUtc,Status,Issues,LastSuccessUtc,Delivery }
    if (Test-Path -LiteralPath $incidentFile) { Read-MonitorJson $incidentFile | Format-List Open,Issues,LastSentUtc }
    return
}

try { $lock=[IO.File]::Open((Join-Path $root 'check.lock'),'OpenOrCreate','ReadWrite','None') }
catch { throw 'Another monitor check is running.' }
try {
    $report=Get-BackupHealth
    $incident=[PSCustomObject]@{Open=$false; Issues=@(); LastSentUtc=''}
    if (Test-Path -LiteralPath $incidentFile) {
        try {
            $incident=Read-MonitorJson $incidentFile
            if ($incident.Open -isnot [bool] -or ($incident.Open -and [string]::IsNullOrWhiteSpace($incident.LastSentUtc))) { throw 'Invalid incident.' }
            if ($incident.Open) { $null=Read-UtcTime $incident.LastSentUtc }
            $null=@($incident.Issues)
        }
        catch {
            $incident=[PSCustomObject]@{Open=$false; Issues=@(); LastSentUtc=''}
            $report.Status='alert'; $report.Issues=@(@($report.Issues)+@('monitor-incident-record-invalid') | Sort-Object -Unique)
        }
    }
    Write-MonitorJson $reportFile $report
    $send=$false; $message=''
    if ($report.Status -eq 'alert') {
        $same=(@($incident.Issues) -join ',') -ceq (@($report.Issues) -join ',')
        $send=(-not $incident.Open) -or (-not $same)
        if (-not $send) { $send=([DateTime]::UtcNow-(Read-UtcTime $incident.LastSentUtc)).TotalMinutes -ge $config.ReminderMinutes }
        $message='[ALERT] PC2 MySQL backup: '+($report.Issues -join ', ')+'. Last successful completion UTC='+$report.LastSuccessUtc+'. Check PC2 backup Status. No automatic DB changes.'
    } elseif ($report.Status -eq 'healthy' -and $incident.Open) {
        $send=$true
        $message='[RECOVERY] PC2 MySQL backup checks are healthy again. Last successful completion UTC='+$report.LastSuccessUtc+'. This does not certify restore success or zero replication lag.'
    }
    if ($send) {
        try { Send-MonitorMessage $message }
        catch { $report.Delivery='failed'; Write-MonitorJson $reportFile $report; throw }
        # Commit dedup/recovery state only after a confirmed delivery, so failed sends retry.
        $incident.Open=$report.Status -eq 'alert'; $incident.Issues=@($report.Issues); $incident.LastSentUtc=[DateTime]::UtcNow.ToString('o')
        Write-MonitorJson $incidentFile $incident
        $report.Delivery='confirmed'; Write-MonitorJson $reportFile $report
    }
    Write-Host ('CHECK: '+$report.Status+'; delivery='+$report.Delivery+'; issues='+($report.Issues -join ','))
    if ($report.Status -eq 'alert') { throw 'Backup health alert detected. See monitor Status and the Discord channel.' }
}
finally { $lock.Dispose() }
