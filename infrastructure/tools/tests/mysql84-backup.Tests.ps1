[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = (Resolve-Path (Join-Path $PSScriptRoot '../mysql84-backup.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-backup-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-Test([bool]$Ok,[string]$Message) { if (-not $Ok) { throw ('ASSERT: '+$Message) } }
function New-Case([string]$Name) {
    $path = Join-Path $testRoot $Name
    $rolePath=Join-Path $path '.secrets/mysql84-replication/pc2'
    $null=New-Item -ItemType Directory -Path $rolePath -Force
    $role=@{Stage='replica-ready';ProductionId='live';ImageId='sha256:fixed84';CloneVolume='live-data';SourceVolume='preserved-original';PrimaryUuid='98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef'}
    [IO.File]::WriteAllText((Join-Path $rolePath 'state.json'),($role|ConvertTo-Json),$utf8)
    $live=[PSCustomObject]@{Id='live';Name='/mysql-lab';Image='sha256:fixed84';State=[PSCustomObject]@{Running=$true;ExitCode=0};Mounts=@([PSCustomObject]@{Type='volume';Name='live-data';Destination='/var/lib/mysql';RW=$true})}
    $global:BackupMock=@{Containers=@{live=$live};Calls=[Collections.Generic.List[object]]::new();Sql=[Collections.Generic.List[object]]::new();Files=@{};Shared=$false;GuardFailure=$false;DumpFailure=$false;Incomplete=$false;Gtid=$false;WrongHeaders=$false;UnsafeMount=$false;PublishedPort=$false;NotReady=$false;RestoreFailure=$false;CheckFailure=$false;BadStop=$false}
    $path
}
function global:Start-Sleep { param($Seconds) }
function global:docker {
    $c=@($args);$m=$global:BackupMock;$global:LASTEXITCODE=0;$m.Calls.Add($c)
    switch ($c[0]) {
        'inspect' {
            if ($c -contains '--format') { 'fixture stopped test';return }
            ConvertTo-Json -InputObject @($m.Containers[$c[1]]) -Depth 9 -Compress;return
        }
        'ps' {
            $volume=$c[[array]::IndexOf($c,'--filter')+1].Substring(7)
            foreach($obj in $m.Containers.Values) { if($obj.State.Running -and @($obj.Mounts | Where-Object { $_.Type -eq 'volume' -and $_.Name -eq $volume }).Count -gt 0) { $obj.Id } }
            if($m.Shared) { 'other-writer' };return
        }
        'cp' {
            if ($c[1] -like 'live:*') { [IO.File]::WriteAllText($c[2],$m.Files[$c[1]],$utf8) }
            else { $m.Files[$c[2]]=[IO.File]::ReadAllText($c[1]) };return
        }
        'exec' {
            if ($c -contains '-it' -and $c -contains 'sh') {
                $sql=$m.Files['live:'+$c[-2]]
                $m.Sql.Add([PSCustomObject]@{Id='live';Text=$sql})
                if($m.GuardFailure) { $global:LASTEXITCODE=1;return }
                $m.Files['live:'+$c[-1]]="1`nloop_table=706F737473`nloop_table=7573657273`n"
            }
            elseif($c -contains 'mysqldump') {
                if($m.DumpFailure) { $global:LASTEXITCODE=1;return }
                $out=@($c | Where-Object { $_ -like '--result-file=*' })[0].Substring(14)
                $second='users';if($m.WrongHeaders) { $second='wrong_table' }
                $dump=@('-- Table structure for table `posts`',('-- Table structure for table `'+$second+'`'),'CREATE DATABASE my_new_board_db;','USE my_new_board_db;','CREATE TABLE posts(id INT PRIMARY KEY) ENGINE=InnoDB;','CREATE TABLE users(id INT PRIMARY KEY) ENGINE=InnoDB;','INSERT INTO posts VALUES(1);')
                if($m.Gtid) { $dump+="SET @@GLOBAL.GTID_PURGED='unexpected';" }
                if(-not $m.Incomplete) { $dump+='-- Dump completed on fixture' }
                $m.Files['live:'+$out]=$dump -join "`n"
            }
            elseif($c[1] -eq 'test' -and $c -contains '-c') { throw 'Inline shell quoting regression in readiness probe.' }
            elseif($c[1] -eq 'test' -and $c -contains '/tmp/loop-restore-ready.sh') {
                Assert-Test ($m.Files['test:/tmp/loop-restore-ready.sh'].Contains('test "$(cat /proc/1/comm)" = mysqld')) 'PID 1 guard missing.'
                Assert-Test (-not $m.Files['test:/tmp/loop-restore-ready.sh'].Contains("`r")) 'Ready runner is not LF.'
                Assert-Test ($m.Files['test:/tmp/loop-restore-ready.sql'] -ceq "SELECT VERSION(),@@GLOBAL.server_id;`n") 'Readiness SQL changed.'
                if($m.NotReady) { $global:LASTEXITCODE=1;return }
                "8.4.11`t9032"
            }
            elseif($c[1] -eq 'test' -and $c -contains '/tmp/loop-restore-file.sh') {
                $sql=$m.Files['test:'+$c[-1]]
                $m.Sql.Add([PSCustomObject]@{Id='test';Text=$sql})
                if($m.RestoreFailure -and $c[-1] -eq '/tmp/loop-restore-snapshot.sql') { $global:LASTEXITCODE=1;return }
                if($c[-1] -eq '/tmp/loop-restore-check.sql') {
                    "my_new_board_db.posts`tcheck`tstatus`tOK"
                    if(-not $m.CheckFailure) { "my_new_board_db.users`tcheck`tstatus`tOK" }
                    "loop_rows=posts`t1";"loop_rows=users`t0"
                }
            }
            return
        }
        'volume' { return }
        'create' {
            $name=$c[[array]::IndexOf($c,'--name')+1]
            $volume=@($c | Where-Object { $_ -like 'type=volume,*' })[0].Split(',')[1].Substring(7)
            if($m.UnsafeMount) { $volume='live-data' }
            $imageIndex=[array]::IndexOf($c,'sha256:fixed84')
            $ports=$null;if($m.PublishedPort) { $ports=[PSCustomObject]@{'3306/tcp'=@{HostPort='3307'}} }
            $m.Containers.test=[PSCustomObject]@{
                Id='test';Name=('/'+$name);Image='sha256:fixed84';State=[PSCustomObject]@{Running=$false;ExitCode=0}
                Config=[PSCustomObject]@{Cmd=@($c[($imageIndex+1)..($c.Count-1)])}
                HostConfig=[PSCustomObject]@{NetworkMode='none';RestartPolicy=[PSCustomObject]@{Name='no'};PortBindings=$ports}
                Mounts=@([PSCustomObject]@{Type='volume';Name=$volume;Destination='/var/lib/mysql';RW=$true},[PSCustomObject]@{Type='bind';Destination='/run/loop-restore';RW=$false})
            }
            'test';return
        }
        'start' { $m.Containers[$c[1]].State.Running=$true;return }
        'stop' { $obj=$m.Containers[$c[-1]];$obj.State.Running=$false;if($m.BadStop) { $obj.State.ExitCode=137 };return }
        default { throw ('Unexpected Docker mock: '+$c[0]) }
    }
}
function Run-Step([string]$Path,[string]$Action) { & $tool -RepositoryPath $Path -Action $Action }
function Expect-Failure([string]$Path,[string]$Action,[string]$Expected) {
    $message='';try { Run-Step $Path $Action } catch { $message=$_.Exception.Message }
    Assert-Test ($message -like ('*'+$Expected+'*')) ('Expected '+$Expected+'; got '+$message)
}
function Read-State([string]$Path) { Get-Content (Join-Path $Path '.secrets/backups/mysql84/pc2/latest.json') -Raw | ConvertFrom-Json }
try {
    # A real native executable exercises PS 5.1 argument serialization that function mocks bypass.
    $nativeProbe = Join-Path $testRoot 'argv-probe.exe'
    Add-Type -TypeDefinition @'
using System;
using System.Text;
public static class LoopNativeArgvProbe {
    public static void Main(string[] args) {
        foreach (string arg in args) Console.WriteLine(Convert.ToBase64String(Encoding.UTF8.GetBytes(arg)));
    }
}
'@ -OutputAssembly $nativeProbe -OutputType ConsoleApplication
    $oldReady = 'test "$(cat /proc/1/comm)" = mysqld && mysql --execute="SELECT VERSION(),@@GLOBAL.server_id;"'
    $oldResult = @(& $nativeProbe $oldReady)
    $oldReceived = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($oldResult[0]))
    if ($PSVersionTable.PSVersion.Major -eq 5) { Assert-Test ($oldReceived -cne $oldReady -and -not $oldReceived.Contains('"SELECT VERSION()')) 'Expected legacy quote loss was not reproduced.' }
    $newArguments = @('exec','test','sh','/tmp/loop-restore-ready.sh','/tmp/loop-restore-ready.sql')
    $newResult = @(& $nativeProbe @newArguments | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) })
    Assert-Test (($newResult -join "`n") -ceq ($newArguments -join "`n")) 'File-based readiness arguments did not survive native serialization.'
    Write-Host 'PASS: real native argument probe reproduces legacy quote loss and validates file-based readiness arguments'
    $p=New-Case 'wrong-live';$global:BackupMock.Containers.live.Mounts[0].Name='preserved-original'
    Expect-Failure $p Backup 'source identity changed'
    Assert-Test ($global:BackupMock.Sql.Count -eq 0) 'Wrong source reached SQL.'
    $p=New-Case 'shared';$global:BackupMock.Shared=$true
    Expect-Failure $p Backup 'shared use'
    $p=New-Case 'unhealthy';$global:BackupMock.GuardFailure=$true
    Expect-Failure $p Backup 'Docker exec failed'
    Assert-Test (@($global:BackupMock.Calls | Where-Object { $_ -contains 'mysqldump' }).Count -eq 0) 'Unhealthy source was dumped.'
    Write-Host 'PASS: wrong/shared live source and failed health guard rejected'

    foreach($failure in @('DumpFailure','Incomplete','WrongHeaders','Gtid')) {
        $p=New-Case $failure;$global:BackupMock[$failure]=$true
        $message='incomplete';if($failure -eq 'DumpFailure') { $message='Docker exec failed' }
        Expect-Failure $p Backup $message
        $state=Read-State $p
        Assert-Test ($state.Stage -ne 'backup-ready' -and -not (Test-Path (Join-Path $state.Directory 'manifest.json'))) 'Invalid dump published.'
    }
    Write-Host 'PASS: failed/incomplete/changed-schema/GTID-bearing dumps not published'

    $p=New-Case 'success';Run-Step $p Backup
    $state=Read-State $p
    $dump=@($global:BackupMock.Calls | Where-Object { $_ -contains 'mysqldump' })[0]
    Assert-Test ($dump -contains '--set-gtid-purged=OFF' -and $dump -contains '--single-transaction' -and $dump -contains '--routines' -and $dump -contains '--events') 'Data-recovery dump options missing.'
    $manifest=Get-Content (Join-Path $state.Directory 'manifest.json') -Raw | ConvertFrom-Json
    Assert-Test ($manifest.Tables.Count -eq 2 -and (Get-FileHash (Join-Path $state.Directory 'snapshot.sql')).Hash -eq $manifest.Sha256) 'Backup metadata/hash incorrect.'
    [IO.File]::AppendAllText((Join-Path $state.Directory 'snapshot.sql'),'tampered')
    Expect-Failure $p RestoreTest 'integrity check'
    Assert-Test (@($global:BackupMock.Calls | Where-Object { $_[0] -eq 'create' }).Count -eq 0) 'Tampered backup created a restore container.'
    $p=New-Case 'changed-manifest';Run-Step $p Backup;$state=Read-State $p
    [IO.File]::AppendAllText((Join-Path $state.Directory 'manifest.json'),' ')
    Expect-Failure $p RestoreTest 'manifest hash changed'
    Assert-Test (@($global:BackupMock.Calls | Where-Object { $_[0] -eq 'create' }).Count -eq 0) 'Changed manifest reached restore creation.'
    Write-Host 'PASS: backup hash, dynamic table list and tamper rejection'

    foreach($failure in @('UnsafeMount','PublishedPort')) {
        $p=New-Case $failure;Run-Step $p Backup;$global:BackupMock[$failure]=$true
        Expect-Failure $p RestoreTest 'Unsafe restore-test'
        Assert-Test (@($global:BackupMock.Calls | Where-Object { $_[0] -in @('start','stop') }).Count -eq 0) 'Unsafe container was started/stopped.'
    }
    Write-Host 'PASS: original/live volume and exposed restore port rejected before start'

    foreach($failure in @('NotReady','RestoreFailure','CheckFailure','BadStop')) {
        $p=New-Case $failure;Run-Step $p Backup;$global:BackupMock[$failure]=$true
        $message='Docker exec failed'
        if($failure -eq 'NotReady') { $message='did not become ready' }
        if($failure -eq 'CheckFailure') { $message='table check' }
        if($failure -eq 'BadStop') { $message='shutdown was not clean' }
        Expect-Failure $p RestoreTest $message
        $state=Read-State $p
        Assert-Test ($state.Stage -ne 'restore-verified' -and $global:BackupMock.Containers.live.State.Running) 'Failed drill claimed success or stopped live DB.'
        if ($failure -eq 'NotReady') {
            Assert-Test ($state.ReadyProbeExitCode -eq 1) 'Readiness failure code was discarded.'
            $global:BackupMock.NotReady=$false
            $before=@($global:BackupMock.Calls | Where-Object { $_[0] -in @('create','volume') }).Count
            Run-Step $p RestoreTest
            Assert-Test ((Read-State $p).Stage -eq 'restore-verified') 'Existing timed-out restore did not resume.'
            Assert-Test (@($global:BackupMock.Calls | Where-Object { $_[0] -in @('create','volume') }).Count -eq $before) 'Timeout retry replaced container/volume.'
        }
    }
    Write-Host 'PASS: initialization, restore, table-check and shutdown failures cannot claim recovery success'

    $p=New-Case 'restore-retry';Run-Step $p Backup;$global:BackupMock.RestoreFailure=$true
    Expect-Failure $p RestoreTest 'Docker exec failed'
    $global:BackupMock.RestoreFailure=$false
    Run-Step $p RestoreTest
    $state=Read-State $p
    Assert-Test ($state.Stage -eq 'restore-verified' -and $global:BackupMock.Containers.live.State.Running -and -not $global:BackupMock.Containers.test.State.Running) 'Successful drill state or original protection failed.'
    Assert-Test ((Test-Path (Join-Path $state.Directory 'restore-report.txt'))) 'Recovery report missing.'
    foreach($call in $global:BackupMock.Calls) {
        Assert-Test ($call[0] -notin @('rm','pull','rename')) 'Unexpected destructive/image-changing operation.'
        if($call[0] -eq 'stop') { Assert-Test ($call[-1] -eq 'test') 'Live container stopped.' }
    }
    foreach($entry in $global:BackupMock.Sql) { if($entry.Id -eq 'live') { Assert-Test (-not $entry.Text.Contains('DROP DATABASE')) 'Production received restore SQL.' } }
    $secret=[IO.File]::ReadAllText((Join-Path $state.Directory 'restore-private/root-password'))
    Assert-Test (-not (($global:BackupMock.Calls | ForEach-Object { $_ -join ' ' }) -join "`n").Contains($secret)) 'Test password leaked into Docker CLI.'
    Run-Step $p RestoreTest;Run-Step $p Status
    Write-Host 'PASS: restore retry, CHECK TABLE/row report, isolated shutdown, secret handling and original preservation'
    Write-Host 'All backup orchestration tests passed. Docker/MySQL simulated; real PC2 backup/restore still required.'
}
finally {
    Remove-Item Function:\docker -ErrorAction SilentlyContinue
    Remove-Item Function:\Start-Sleep -ErrorAction SilentlyContinue
    Remove-Variable BackupMock -Scope Global -ErrorAction SilentlyContinue
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path $resolved -Leaf) -notlike 'loop-backup-tests-*') { throw 'Unsafe temporary cleanup target.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
