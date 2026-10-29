[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RepositoryPath,
    [ValidateSet('Prepare', 'SaveWebhook', 'Update', 'TestAlert', 'Check', 'Install', 'Status')][string]$Action = 'Status',
    [ValidateSet('Replica', 'Primary')][string]$SourceRole = 'Replica'
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This monitor requires Windows and the original PC2 Windows user.' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$replicaRoot = Join-Path $repo '.secrets/backups/mysql84/pc2'
$backupRoot = if ($SourceRole -eq 'Primary') { Join-Path $repo '.secrets/backups/mysql84/pc2-primary' } else { $replicaRoot }
$scheduler = Join-Path $backupRoot 'scheduler'
$root = Join-Path $backupRoot 'discord-monitor'
$configFile = Join-Path $root 'config.json'
$credentialFile = Join-Path $root 'webhook.clixml'
$workerFile = Join-Path $root 'mysql84-backup-discord.ps1'
$reportFile = Join-Path $root 'last-check.json'
$incidentFile = Join-Path $root 'incident.json'
$receiptFile = Join-Path $root 'test-delivery.json'
$taskName = if ($SourceRole -eq 'Primary') { 'Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor' } else { 'Loop-MySQL84-PC2-Backup-Discord-Monitor' }
$backupTaskName = if ($SourceRole -eq 'Primary') { 'Loop-MySQL84-PC2-Primary-Hourly-Backup' } else { 'Loop-MySQL84-PC2-Hourly-Backup' }
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
    if ($SourceRole -eq 'Primary' -and ($null -eq $value.PSObject.Properties['SourceRole'] -or $value.SourceRole -cne 'Primary' -or $null -eq $value.PSObject.Properties['ActivationPending'])) { throw 'Primary monitor role or activation state is missing.' }
    if ((Get-FileHash -LiteralPath $workerFile).Hash -ine $value.WorkerSha256) { throw 'Installed monitor hash changed. No message or task update was attempted.' }
    $value
}
function Get-MonitorArguments {
    $roleArgument = if ($SourceRole -eq 'Primary') { ' -SourceRole Primary' } else { '' }
    '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $workerFile + '" -RepositoryPath "' + $repo + '" -Action Check' + $roleArgument
}
function New-MonitorDirectory {
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
}
function Assert-PrimaryMonitorTask {
    [xml]$xml=Export-ScheduledTask -TaskName $taskName -TaskPath '\'
    $ns=[Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('t','http://schemas.microsoft.com/windows/2004/02/mit/task')
    $principal=$xml.SelectSingleNode('/t:Task/t:Principals/t:Principal',$ns)
    $ownerSid=$principal.UserId
    if ($ownerSid -notlike 'S-1-*') { $ownerSid=[Security.Principal.NTAccount]::new($ownerSid).Translate([Security.Principal.SecurityIdentifier]).Value }
    $exec=$xml.SelectNodes('/t:Task/t:Actions/t:Exec',$ns)
    $triggers=$xml.SelectNodes('/t:Task/t:Triggers/*',$ns)
    $settings=$xml.SelectSingleNode('/t:Task/t:Settings',$ns)
    $duration=$xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Duration',$ns)
    $effective=Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    if ($ownerSid -ne $sid -or $principal.LogonType -ne 'InteractiveToken' -or [string]$effective.Principal.RunLevel -ne 'Limited' -or $exec.Count -ne 1 -or $exec[0].Command -ne $powershell -or $exec[0].Arguments -cne (Get-MonitorArguments) -or $exec[0].WorkingDirectory -ne $repo -or $triggers.Count -ne 1 -or $triggers[0].LocalName -ne 'TimeTrigger' -or [Xml.XmlConvert]::ToTimeSpan($triggers[0].Repetition.Interval).TotalMinutes -ne 5 -or $null -ne $duration -or [Xml.XmlConvert]::ToTimeSpan($settings.ExecutionTimeLimit).TotalMinutes -ne 2 -or $settings.StartWhenAvailable -ne 'true') { throw 'Prepared Primary monitor task definition changed. No task was enabled.' }
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
function Format-MessageTime([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return '확인할 수 없음' }
    ([DateTimeOffset](Read-UtcTime $Value)).ToOffset([TimeSpan]::FromHours(9)).ToString("yyyy-MM-dd HH:mm:ss 'KST'")
}
function Format-Elapsed([string]$StartedUtc, [string]$CheckedUtc) {
    $seconds=[Math]::Max(0,[Math]::Floor(((Read-UtcTime $CheckedUtc)-(Read-UtcTime $StartedUtc)).TotalSeconds))
    $hours=[Math]::Floor($seconds/3600); $minutes=[Math]::Floor(($seconds%3600)/60); $remainder=$seconds%60
    if ($hours -gt 0) { return ('{0}시간 {1}분 {2}초' -f $hours,$minutes,$remainder) }
    '{0}분 {1}초' -f $minutes,$remainder
}
function Get-NotificationMessage($Report, [bool]$Recovery=$false) {
    $lines=[Collections.Generic.List[string]]::new()
    if ($Recovery) { $lines.Add('[RECOVERY] PC2 MySQL 백업 정상화') }
    else { $lines.Add('[ALERT] PC2 MySQL 백업 이상') }
    if ($SourceRole -eq 'Primary') { $lines.Add('백업 역할: PC2 Primary') }
    $lines.Add('확인 시각: '+(Format-MessageTime $Report.CheckedUtc))
    if ($Recovery) { $lines.Add('백업 감시 항목이 정상 상태로 돌아왔습니다.') }
    else {
        foreach ($issue in $Report.Issues) {
            $text=switch ($issue) {
                'no-success-within-90-minutes' { (Format-MessageTime $Report.LastSuccessUtc)+' 마지막 백업 성공 이후 '+(Format-Elapsed $Report.LastSuccessUtc $Report.CheckedUtc)+' 동안 새 백업이 성공적으로 완료되지 않았습니다. (기준: 90분)' }
                'backup-running-over-12-minutes' {
                    if ($Report.RunningStartedUtc) { '백업 작업이 '+(Format-MessageTime $Report.RunningStartedUtc)+'에 시작된 뒤 '+(Format-Elapsed $Report.RunningStartedUtc $Report.CheckedUtc)+' 동안 완료되지 않았습니다. (기준: 12분)' }
                    else { '백업 실행 상태가 12분을 초과했습니다. 시작 시각은 확인할 수 없습니다.' }
                }
                'backup-failed' { '최근 백업 작업이 실패했습니다.' }
                'backup-task-exit-nonzero' { '백업 예약 작업이 오류 코드로 종료됐습니다.' }
                'backup-task-not-ready' { '백업 예약 작업이 비활성화됐거나 정상 대기 상태가 아닙니다.' }
                'backup-task-unavailable' { '백업 예약 작업을 찾거나 조회할 수 없습니다.' }
                'backup-run-record-invalid' { '최근 백업 실행 기록이 없거나 손상돼 상태를 확인할 수 없습니다.' }
                'backup-success-record-invalid' { '백업 성공 기록이 없거나 손상돼 마지막 성공 시각을 확인할 수 없습니다.' }
                'last-backup-files-unavailable' { '마지막 성공 백업의 덤프 또는 manifest 파일을 찾을 수 없습니다.' }
                'monitor-incident-record-invalid' { '이전 알림 상태 기록이 손상됐습니다.' }
                default { '백업 감시 중 확인이 필요한 상태가 감지됐습니다.' }
            }
            $lines.Add('- '+$text)
        }
    }
    if ($Report.Issues -notcontains 'no-success-within-90-minutes') { $lines.Add('마지막 백업 성공: '+(Format-MessageTime $Report.LastSuccessUtc)) }
    if (-not $Recovery -and $Report.LastRunStartedUtc) {
        $lines.Add('최근 백업 시작: '+(Format-MessageTime $Report.LastRunStartedUtc))
        if ($Report.LastRunCompletedUtc) { $lines.Add('최근 백업 종료: '+(Format-MessageTime $Report.LastRunCompletedUtc)+' / 소요 '+(Format-Elapsed $Report.LastRunStartedUtc $Report.LastRunCompletedUtc)) }
    }
    $lines.Add('PC2 Windows에서 백업 Status를 확인해 주세요.')
    $lines -join "`n"
}
function Get-BackupHealth {
    $now = [DateTime]::UtcNow
    $issues = [Collections.Generic.List[string]]::new()
    $pending = $false; $successUtc = ''; $runStartedUtc=''; $runCompletedUtc=''; $runningStartedUtc=''
    try {
        $task = Get-ScheduledTask -TaskName $backupTaskName -TaskPath '\' -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $backupTaskName -TaskPath '\' -ErrorAction Stop
        if ([string]$task.State -notin @('Ready','Running')) { $issues.Add('backup-task-not-ready') }
        if ([string]$task.State -eq 'Running') {
            $pending=$true
            $runningStartedUtc=$info.LastRunTime.ToUniversalTime().ToString('o')
            if (($now-$info.LastRunTime.ToUniversalTime()).TotalMinutes -gt $config.RunningMinutes) { $issues.Add('backup-running-over-12-minutes') }
        }
        elseif ($info.LastTaskResult -ne 0) { $issues.Add('backup-task-exit-nonzero') }
    }
    catch { $issues.Add('backup-task-unavailable') }
    try {
        $last = Read-MonitorJson (Join-Path $scheduler 'last-run.json')
        if ($SourceRole -eq 'Primary' -and ($null -eq $last.PSObject.Properties['SourceRole'] -or $last.SourceRole -cne 'Primary')) { throw 'Wrong backup record role.' }
        $started = Read-UtcTime $last.StartedUtc
        if ($started -gt $now.AddMinutes(5)) { throw 'Future timestamp.' }
        $runStartedUtc=$started.ToString('o')
        switch ($last.Status) {
            'failed' { $issues.Add('backup-failed') }
            'running' {
                $pending=$true
                if (-not $runningStartedUtc -or $started -lt (Read-UtcTime $runningStartedUtc)) { $runningStartedUtc=$started.ToString('o') }
                if (($now-$started).TotalMinutes -gt $config.RunningMinutes) { $issues.Add('backup-running-over-12-minutes') }
            }
            'success' {
                $completed = Read-UtcTime $last.CompletedUtc
                if ($completed -lt $started -or $completed -gt $now.AddMinutes(5) -or $last.ExitCode -ne 0) { throw 'Invalid completion record.' }
            }
            default { throw 'Unknown backup status.' }
        }
        if ($last.Status -in @('success','failed')) {
            $completed=Read-UtcTime $last.CompletedUtc
            if ($completed -lt $started -or $completed -gt $now.AddMinutes(5)) { throw 'Invalid completion time.' }
            $runCompletedUtc=$completed.ToString('o')
        }
    }
    catch { $issues.Add('backup-run-record-invalid') }
    try {
        $success = Read-MonitorJson (Join-Path $scheduler 'last-success.json')
        if ($SourceRole -eq 'Primary' -and ($null -eq $success.PSObject.Properties['SourceRole'] -or $success.SourceRole -cne 'Primary')) { throw 'Wrong success record role.' }
        $completed = Read-UtcTime $success.CompletedUtc
        $started = Read-UtcTime $success.StartedUtc
        if ($success.Status -ne 'success' -or $success.ExitCode -ne 0 -or $completed -lt $started -or $completed -gt $now.AddMinutes(5)) { throw 'Invalid success record.' }
        $successUtc = $completed.ToString('o')
        if (($now-$completed).TotalMinutes -gt $config.StaleMinutes) { $issues.Add('no-success-within-90-minutes') }
        if ((Split-Path -Path $success.BackupDirectory -Parent) -ne $backupRoot -or
            -not (Test-Path -LiteralPath (Join-Path $success.BackupDirectory 'manifest.json') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $success.BackupDirectory 'snapshot.sql') -PathType Leaf)) { $issues.Add('last-backup-files-unavailable') }
    }
    catch { $issues.Add('backup-success-record-invalid') }
    $status='healthy'
    if ($issues.Count -gt 0) { $status='alert' } elseif ($pending) { $status='pending' }
    [PSCustomObject]@{CheckedUtc=$now.ToString('o'); Status=$status; Issues=@($issues.ToArray() | Sort-Object -Unique); LastSuccessUtc=$successUtc; LastRunStartedUtc=$runStartedUtc; LastRunCompletedUtc=$runCompletedUtc; RunningStartedUtc=$runningStartedUtc; Delivery='not-needed'}
}

if ($Action -eq 'Prepare') {
    if ($SourceRole -ne 'Primary') { throw 'Prepare is only for a separate disabled Primary monitor.' }
    $backupConfig=Read-MonitorJson (Join-Path $scheduler 'config.json')
    if ($backupConfig.OwnerSid -ne $sid -or $backupConfig.RepositoryPath -ne $repo -or $backupConfig.TaskName -ne $backupTaskName -or $backupConfig.SourceRole -cne 'Primary') { throw 'Prepare the Primary backup schedule first with the original PC2 user.' }
    if (-not (Test-Path -LiteralPath $configFile)) {
        if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Primary monitor task already exists without this configuration.' }
        $originalRoot=Join-Path $replicaRoot 'discord-monitor'
        $originalConfig=Read-MonitorJson (Join-Path $originalRoot 'config.json')
        $originalCredential=Join-Path $originalRoot 'webhook.clixml'
        if ($originalConfig.OwnerSid -ne $sid -or $originalConfig.RepositoryPath -ne $repo -or ((Get-Item -LiteralPath $originalCredential).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Original Replica webhook identity changed.' }
        $credential=Import-Clixml -LiteralPath $originalCredential
        if ($credential -isnot [Management.Automation.PSCredential] -or $credential.UserName -cne 'discord-webhook') { throw 'Original encrypted webhook is unavailable.' }
        $credential=$null
        New-MonitorDirectory
        Copy-Item -LiteralPath $originalCredential -Destination $credentialFile
        Copy-Item -LiteralPath $PSCommandPath -Destination $workerFile
        Write-MonitorJson $configFile ([PSCustomObject]@{Format='loop-mysql84-discord-v1'; SourceRole='Primary'; ActivationPending=$true; OwnerSid=$sid; RepositoryPath=$repo; WorkerSha256=(Get-FileHash -LiteralPath $workerFile).Hash; StaleMinutes=90; RunningMinutes=12; ReminderMinutes=60})
    }
    $config=Read-MonitorConfig
    if (-not (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue)) {
        $taskAction=New-ScheduledTaskAction -Execute $powershell -Argument (Get-MonitorArguments) -WorkingDirectory $repo
        $trigger=New-ScheduledTaskTrigger -Once -At ((Get-Date).AddMinutes(1)) -RepetitionInterval (New-TimeSpan -Minutes 5)
        $principal=New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings=New-ScheduledTaskSettingsSet -Disable -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 2) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null=Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Prepared Primary backup monitor; disabled until Primary backup validation and explicit activation.'
    }
    Assert-PrimaryMonitorTask
    if (-not $config.ActivationPending -or (Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -ne 'Disabled') { throw 'Primary monitor is not in the prepared/disabled state. No task was disabled or replaced.' }
    Write-Host 'PASS: Primary Discord monitor prepared DISABLED. Existing Replica monitor unchanged. No message or DB change performed.'
    return
}
if ($Action -eq 'SaveWebhook') {
    if ($SourceRole -eq 'Primary') { throw 'Use Prepare to reuse the encrypted Replica webhook without replacing it.' }
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
if ($Action -eq 'Update') {
    # This update path is for the verified webhook/test stage, before installing the monitor task.
    if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Monitor task already installed. This update requires the pre-install stage; no files were changed.' }
    if ($PSCommandPath -eq $workerFile) { throw 'Run Update from the newly downloaded source, not the installed worker.' }
    try { $updateLock=[IO.File]::Open((Join-Path $root 'check.lock'),'OpenOrCreate','ReadWrite','None') }
    catch { throw 'Another monitor check is running. Wait before updating.' }
    $previousWorker=[IO.File]::ReadAllBytes($workerFile)
    $previousConfig=[IO.File]::ReadAllBytes($configFile)
    $replacement=Join-Path $root ('update-'+[guid]::NewGuid().ToString('N')+'.tmp')
    try {
        Copy-Item -LiteralPath $PSCommandPath -Destination $replacement
        [IO.File]::Replace($replacement,$workerFile,[NullString]::Value)
        $config.WorkerSha256=(Get-FileHash -LiteralPath $workerFile).Hash
        Write-MonitorJson $configFile $config
        $null=Read-MonitorConfig
    }
    catch {
        [IO.File]::WriteAllBytes($workerFile,$previousWorker)
        [IO.File]::WriteAllBytes($configFile,$previousConfig)
        throw 'Monitor update failed; previous worker and configuration restored. Webhook and backup settings were retained.'
    }
    finally {
        if (Test-Path -LiteralPath $replacement) { Remove-Item -LiteralPath $replacement -Force }
        $updateLock.Dispose()
    }
    Write-Host 'PASS: monitor message code updated. Saved webhook and backup settings retained. Next run TestAlert.'
    return
}
if ($Action -eq 'TestAlert') {
    $roleLabel=if ($SourceRole -eq 'Primary') { 'PC2 MySQL Primary' } else { 'PC2 MySQL' }
    Send-MonitorMessage ("[TEST] $roleLabel 백업 알림 전송 시험`n전송 시각: "+(Format-MessageTime ([DateTime]::UtcNow.ToString('o')))+"`nDiscord 알림 전송을 확인하는 시험입니다. 실제 백업 실패나 DB 변경은 발생시키지 않았습니다.")
    Write-MonitorJson $receiptFile ([PSCustomObject]@{DeliveredUtc=[DateTime]::UtcNow.ToString('o'); Kind='test-only'; WorkerSha256=$config.WorkerSha256})
    Write-Host 'PASS: Discord confirmed the TEST message. Verify it in the selected channel.'
    return
}
if ($Action -eq 'Install') {
    $receipt=Read-MonitorJson $receiptFile
    $tested=Read-UtcTime $receipt.DeliveredUtc
    if ($receipt.Kind -ne 'test-only' -or $tested -lt [DateTime]::UtcNow.AddDays(-1) -or $tested -gt [DateTime]::UtcNow.AddMinutes(5) -or $null -eq $receipt.PSObject.Properties['WorkerSha256'] -or $receipt.WorkerSha256 -ine $config.WorkerSha256) { throw 'Run TestAlert successfully with the current worker before installing the monitor.' }
    if ($SourceRole -eq 'Primary') {
        Assert-PrimaryMonitorTask
        $health=Get-BackupHealth
        if ($health.Status -ne 'healthy') { throw 'Primary monitor activation requires a healthy real Primary scheduled backup. Task remains disabled.' }
        $config.ActivationPending=$false
        Write-MonitorJson $configFile $config
        $null=Enable-ScheduledTask -TaskName $taskName -TaskPath '\'
        Write-Host 'PASS: Primary monitor activated after confirmed test delivery and healthy Primary backup records.'
        return
    }
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
    if ($SourceRole -eq 'Primary') { Write-Host ('Primary activation pending: '+$config.ActivationPending) }
    $task=Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if ($task) {
        $info=Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
        Write-Host ('Monitor task: '+$taskName+'; state='+$task.State+'; result='+$info.LastTaskResult+'; next='+$info.NextRunTime)
    } else { Write-Host 'Monitor task not installed.' }
    if (Test-Path -LiteralPath $reportFile) { Read-MonitorJson $reportFile | Format-List CheckedUtc,Status,Issues,LastSuccessUtc,Delivery }
    if (Test-Path -LiteralPath $incidentFile) { Read-MonitorJson $incidentFile | Format-List Open,Issues,LastSentUtc }
    return
}

if ($SourceRole -eq 'Primary' -and $config.ActivationPending) { throw 'Primary monitor is prepared only. Check is blocked until Primary backup validation and Install.' }

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
        $message=Get-NotificationMessage $report
    } elseif ($report.Status -eq 'healthy' -and $incident.Open) {
        $send=$true
        $message=Get-NotificationMessage $report -Recovery $true
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
