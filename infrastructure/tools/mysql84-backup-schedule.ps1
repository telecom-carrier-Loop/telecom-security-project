[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$RepositoryPath,
    [ValidateSet('Install', 'Repair', 'Run', 'Test', 'Status')][string]$Action = 'Status',
    [string]$BackupToolPath
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
if ($env:OS -ne 'Windows_NT') { throw 'This scheduler requires Windows.' }
$repo = (Resolve-Path -LiteralPath $RepositoryPath).Path
$backupRoot = Join-Path $repo '.secrets/backups/mysql84/pc2'
$root = Join-Path $backupRoot 'scheduler'
$configFile = Join-Path $root 'config.json'
$runFile = Join-Path $root 'last-run.json'
$successFile = Join-Path $root 'last-success.json'
$workerFile = Join-Path $root 'mysql84-backup-schedule.ps1'
$backupFile = Join-Path $root 'mysql84-backup.ps1'
$taskName = 'Loop-MySQL84-PC2-Hourly-Backup'
$sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$powershell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
$utf8 = [Text.UTF8Encoding]::new($false)

function Write-ScheduleJson([string]$Path, $Value) {
    $temporary = $Path + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
    try {
        [IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 8), $utf8)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}
function New-ScheduleDirectory {
    $null = New-Item -ItemType Directory -Path $root -Force
    if (((Get-Item -LiteralPath $root).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Scheduler directory cannot be a reparse point.' }
    $acl = Get-Acl -LiteralPath $root
    $owner = [Security.Principal.SecurityIdentifier]::new($sid)
    $acl.SetOwner($owner)
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) { $acl.RemoveAccessRuleSpecific($rule) }
    foreach ($identity in @($owner, [Security.Principal.SecurityIdentifier]::new('S-1-5-18'))) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow'))
    }
    Set-Acl -LiteralPath $root -AclObject $acl
}
function Read-ScheduleConfig {
    $value = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
    if ($value.Format -ne 'loop-mysql84-hourly-v1' -or $value.RepositoryPath -ne $repo -or $value.OwnerSid -ne $sid -or $value.TaskName -ne $taskName) { throw 'Scheduler identity changed. Use the original PC2 Windows user.' }
    foreach ($entry in @(@($workerFile, $value.WorkerSha256), @($backupFile, $value.BackupSha256))) {
        $item = Get-Item -LiteralPath $entry[0]
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Get-FileHash -LiteralPath $entry[0]).Hash -ine $entry[1]) { throw 'Installed scheduler/backup tool hash changed. No backup was started.' }
    }
    if (-not (Test-Path -LiteralPath $value.DockerPath -PathType Leaf)) { throw 'Recorded Docker CLI is unavailable.' }
    $value
}
function Get-WorkerArguments {
    '-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy RemoteSigned -File "' + $workerFile + '" -RepositoryPath "' + $repo + '" -Action Run'
}
function Assert-ScheduleTask {
    [xml]$xml = Export-ScheduledTask -TaskName $taskName -TaskPath '\'
    $ns = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $principal = $xml.SelectSingleNode('/t:Task/t:Principals/t:Principal', $ns)
    $registeredSid = $principal.UserId
    if ($registeredSid -notlike 'S-1-*') { $registeredSid = [Security.Principal.NTAccount]::new($registeredSid).Translate([Security.Principal.SecurityIdentifier]).Value }
    $exec = $xml.SelectNodes('/t:Task/t:Actions/t:Exec', $ns)
    $triggers = $xml.SelectNodes('/t:Task/t:Triggers/*', $ns)
    $settings = $xml.SelectSingleNode('/t:Task/t:Settings', $ns)
    $duration = $xml.SelectSingleNode('/t:Task/t:Triggers/t:TimeTrigger/t:Repetition/t:Duration', $ns)
    # Export-ScheduledTask can omit defaults. Check the effective CIM run level as well.
    $effective = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    $runLevel = $xml.SelectSingleNode('/t:Task/t:Principals/t:Principal/t:RunLevel', $ns)
    $instances = $xml.SelectSingleNode('/t:Task/t:Settings/t:MultipleInstancesPolicy', $ns)
    $instancesPolicy = 'IgnoreNew'
    if ($null -ne $instances) { $instancesPolicy = $instances.InnerText }
    if ($registeredSid -ne $sid -or $principal.LogonType -ne 'InteractiveToken' -or [string]$effective.Principal.RunLevel -ne 'Limited' -or ($null -ne $runLevel -and $runLevel.InnerText -ne 'LeastPrivilege') -or $exec.Count -ne 1 -or $exec[0].Command -ne $powershell -or $exec[0].Arguments -cne (Get-WorkerArguments) -or $exec[0].WorkingDirectory -ne $repo -or $triggers.Count -ne 1 -or $triggers[0].LocalName -ne 'TimeTrigger' -or [Xml.XmlConvert]::ToTimeSpan($triggers[0].Repetition.Interval).TotalHours -ne 1 -or $null -ne $duration -or $instancesPolicy -ne 'IgnoreNew' -or [Xml.XmlConvert]::ToTimeSpan($settings.ExecutionTimeLimit).TotalMinutes -ne 10 -or $settings.StartWhenAvailable -ne 'true') {
        throw 'Registered task differs from the hourly/current-user/limited backup definition. No task was started or replaced.'
    }
}
function Show-ScheduleStatus {
    Assert-ScheduleTask
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
    Write-Host ('Task: ' + $taskName)
    Write-Host 'Interval: 1 hour; current user must be logged on; PC and Docker Desktop must be running.'
    Write-Host ('Task state: ' + $task.State)
    Write-Host ('Last task result: 0x' + ('{0:X8}' -f [uint32]$info.LastTaskResult))
    Write-Host ('Next run: ' + $info.NextRunTime)
    foreach ($path in @($runFile, $successFile)) {
        if (Test-Path -LiteralPath $path) {
            $record = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
            Write-Host ((Split-Path $path -Leaf) + ': ' + $record.Status + '; started=' + $record.StartedUtc + '; completed=' + $record.CompletedUtc)
            Write-Host ('Backup directory: ' + $record.BackupDirectory)
            Write-Host ('Private log: ' + $record.Log)
        }
    }
}

if ($Action -eq 'Install') {
    if (-not (Test-Path -LiteralPath $configFile)) {
        if (Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue) { throw 'Task name already exists without this installation. It will not be replaced.' }
        $verified = Get-Content -LiteralPath (Join-Path $backupRoot 'latest.json') -Raw | ConvertFrom-Json
        if ($verified.Stage -ne 'restore-verified') { throw 'Finish the saved-account backup and isolated restore test before installing the schedule.' }
        $credential = Import-Clixml -LiteralPath (Join-Path $backupRoot 'credentials/loop_backup.clixml')
        if ($credential -isnot [Management.Automation.PSCredential] -or $credential.UserName -cne 'loop_backup' -or $credential.Password.Length -eq 0) { throw 'Expected this Windows user''s encrypted loop_backup credential.' }
        $credential = $null
        if ([string]::IsNullOrWhiteSpace($BackupToolPath)) { throw 'BackupToolPath is required for the first installation.' }
        $sourceTool = (Resolve-Path -LiteralPath $BackupToolPath).Path
        $docker = (Get-Command docker -CommandType Application -ErrorAction Stop).Source
        New-ScheduleDirectory
        Copy-Item -LiteralPath $PSCommandPath -Destination $workerFile
        Copy-Item -LiteralPath $sourceTool -Destination $backupFile
        $config = [PSCustomObject]@{
            Format='loop-mysql84-hourly-v1'; RepositoryPath=$repo; OwnerSid=$sid; TaskName=$taskName
            DockerPath=$docker; WorkerSha256=(Get-FileHash -LiteralPath $workerFile).Hash
            BackupSha256=(Get-FileHash -LiteralPath $backupFile).Hash; CreatedUtc=[DateTime]::UtcNow.ToString('o')
            VerifiedRestoreDirectory=$verified.Directory
        }
        Write-ScheduleJson $configFile $config
    }
    $config = Read-ScheduleConfig
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\' -ErrorAction SilentlyContinue
    if (-not $task) {
        $taskAction = New-ScheduledTaskAction -Execute $powershell -Argument (Get-WorkerArguments) -WorkingDirectory $repo
        # Omitting RepetitionDuration repeats indefinitely; do not use TimeSpan.MaxValue.
        $trigger = New-ScheduledTaskTrigger -Once -At ((Get-Date).AddHours(1)) -RepetitionInterval (New-TimeSpan -Hours 1)
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        $settings = New-ScheduledTaskSettingsSet -Disable -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        $null = Register-ScheduledTask -TaskName $taskName -TaskPath '\' -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Description 'Hourly PC2 MySQL backup using the current Windows user and encrypted loop_backup credential.'
    }
    Assert-ScheduleTask
    $null = Enable-ScheduledTask -TaskName $taskName -TaskPath '\'
    Write-Host 'PASS: hourly backup task installed. Next run Test to verify a real Task Scheduler execution.'
    Show-ScheduleStatus
    exit 0
}

$config = Read-ScheduleConfig
if ($Action -eq 'Repair') {
    Assert-ScheduleTask
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    if ($task.State -eq 'Running') { throw 'Task is running. Wait for completion before Repair; it will not be stopped.' }
    $null = Disable-ScheduledTask -TaskName $taskName -TaskPath '\'
    if ((Get-ScheduledTask -TaskName $taskName -TaskPath '\').State -eq 'Running') { throw 'Task started during repair preparation. Wait for completion; it will not be stopped.' }
    $newHash = (Get-FileHash -LiteralPath $PSCommandPath).Hash
    if ($newHash -ine $config.WorkerSha256) {
        $previousBytes = [IO.File]::ReadAllBytes($workerFile)
        $previousHash = $config.WorkerSha256
        $replacement = Join-Path $root ('worker-repair-' + [guid]::NewGuid().ToString('N') + '.tmp')
        try {
            Copy-Item -LiteralPath $PSCommandPath -Destination $replacement
            [IO.File]::Replace($replacement, $workerFile, [NullString]::Value)
            $config.WorkerSha256 = $newHash
            Write-ScheduleJson $configFile $config
            $null = Read-ScheduleConfig
        }
        catch {
            [IO.File]::WriteAllBytes($replacement, $previousBytes)
            [IO.File]::Replace($replacement, $workerFile, [NullString]::Value)
            $config.WorkerSha256 = $previousHash
            Write-ScheduleJson $configFile $config
            throw 'Worker repair failed and the original snapshot was restored. Task remains disabled; inspect Status.'
        }
        finally { if (Test-Path -LiteralPath $replacement) { Remove-Item -LiteralPath $replacement -Force } }
    }
    Assert-ScheduleTask
    $null = Enable-ScheduledTask -TaskName $taskName -TaskPath '\'
    Write-Host 'PASS: scheduler worker repaired and the existing hourly task enabled. Next run Test.'
    Show-ScheduleStatus
    exit 0
}
if ($Action -eq 'Status') { Show-ScheduleStatus; exit 0 }
if ($Action -eq 'Test') {
    Assert-ScheduleTask
    $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
    if ($task.State -eq 'Running') { throw 'Task is already running. Run Status instead of starting another test.' }
    if ($task.State -eq 'Disabled') { throw 'Task is disabled. Inspect Status before enabling it.' }
    $beforeId = ''
    if (Test-Path -LiteralPath $runFile) { $beforeId = (Get-Content -LiteralPath $runFile -Raw | ConvertFrom-Json).RunId }
    $beforeTaskTime = (Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\').LastRunTime
    Start-ScheduledTask -TaskName $taskName -TaskPath '\'
    for ($attempt=0; $attempt -lt 45; $attempt++) {
        if (Test-Path -LiteralPath $runFile) {
            $record = Get-Content -LiteralPath $runFile -Raw | ConvertFrom-Json
            if ($record.RunId -ne $beforeId -and $record.Status -eq 'failed') { throw 'Scheduled backup failed. Run Status and inspect the private log; do not recreate credentials.' }
            $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
            if ($record.RunId -ne $beforeId -and $record.Status -eq 'success' -and $task.State -ne 'Running') {
                $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
                if ($info.LastTaskResult -ne 0) { throw 'Task Scheduler returned a failure result. Run Status.' }
                Write-Host 'PASS: real Task Scheduler execution created a new complete backup; task result=0.'
                Show-ScheduleStatus
                exit 0
            }
        }
        $task = Get-ScheduledTask -TaskName $taskName -TaskPath '\'
        $info = Get-ScheduledTaskInfo -TaskName $taskName -TaskPath '\'
        if ($task.State -ne 'Running' -and $info.LastRunTime -gt $beforeTaskTime -and $info.LastTaskResult -ne 0) { throw 'Task Scheduler returned a failure result before completion was recorded. Run Status.' }
        if ($attempt % 5 -eq 0) { Write-Host 'Waiting for the scheduled backup result...' }
        Start-Sleep -Seconds 2
    }
    throw 'No completed scheduled backup was confirmed within 90 seconds. Run Status; the task may still be running.'
}

# Run is the sole task entry point. It never registers tasks, prompts, restores, or removes backups.
try { $runLock = [IO.File]::Open((Join-Path $root 'run.lock'), 'OpenOrCreate', 'ReadWrite', 'None') }
catch { throw 'Another scheduled worker is running.' }
try {
    $runId = [guid]::NewGuid().ToString('N')
    $record = [PSCustomObject]@{RunId=$runId; Status='running'; StartedUtc=[DateTime]::UtcNow.ToString('o'); CompletedUtc=''; ExitCode=$null; BackupDirectory=''; Log=(Join-Path $root ('run-' + $runId + '.log'))}
    Write-ScheduleJson $runFile $record
    $previousDirectory = ''
    $latest = Join-Path $backupRoot 'latest.json'
    $oldPath = $env:PATH
    try {
        if (Test-Path -LiteralPath $latest) { $previousDirectory = (Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json).Directory }
        $env:PATH = (Split-Path -Path $config.DockerPath -Parent) + ';' + $env:PATH
        $global:LASTEXITCODE = 0
        & $backupFile -RepositoryPath $repo -Action BackupSaved *> $record.Log
        if ($LASTEXITCODE -ne 0) { throw 'BackupSaved returned a failure code.' }
        $result = Get-Content -LiteralPath $latest -Raw | ConvertFrom-Json
        if ($result.Stage -ne 'backup-ready' -or $result.Directory -eq $previousDirectory -or (Split-Path -Path $result.Directory -Parent) -ne $backupRoot -or -not (Test-Path -LiteralPath (Join-Path $result.Directory 'manifest.json'))) { throw 'No new complete backup was recorded.' }
        $record.Status = 'success'; $record.ExitCode = 0; $record.CompletedUtc = [DateTime]::UtcNow.ToString('o'); $record.BackupDirectory = $result.Directory
        Write-ScheduleJson $successFile $record
        Write-ScheduleJson $runFile $record
        Write-Host 'PASS: scheduled BackupSaved completed.'
    }
    catch {
        $record.Status = 'failed'; $record.ExitCode = 1; $record.CompletedUtc = [DateTime]::UtcNow.ToString('o')
        Write-ScheduleJson $runFile $record
        Write-Host ('FAIL: scheduled backup. Inspect private log: ' + $record.Log)
        exit 1
    }
    finally { $env:PATH = $oldPath }
}
finally { $runLock.Dispose() }
