[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$tool = (Resolve-Path (Join-Path $PSScriptRoot '../mysql84-replica.ps1')).Path
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('loop-replica-tests-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$utf8 = [Text.UTF8Encoding]::new($false)
function Assert-Test([bool]$Ok, [string]$Message) { if (-not $Ok) { throw ('ASSERT: ' + $Message) } }
function New-Case([string]$Name) {
    $path = Join-Path $testRoot $Name
    $bundle = Join-Path $path '.secrets/mysql84-replication/incoming/pc2-transfer'
    $null = New-Item -ItemType Directory -Path $bundle -Force
    $files = @()
    foreach ($name in @('snapshot.sql','ca.pem','client-cert.pem','client-key.pem','replication-password')) {
        $value = 'fixture ' + $name
        if ($name -eq 'replication-password') { $value = 'Lp9!' + ('a' * 64) }
        if ($name -eq 'snapshot.sql') { $value = "SET @@GLOBAL.GTID_PURGED='';`nCREATE DATABASE my_new_board_db;`n-- Dump completed on fixture" }
        $file = Join-Path $bundle $name
        [IO.File]::WriteAllText($file, $value, $utf8)
        $files += @{Path=$name; Length=(Get-Item $file).Length; Sha256=(Get-FileHash $file).Hash}
    }
    $manifest = @{ Format='loop-mysql84-seed-v1'; PrimaryAddress='192.168.3.18'; PrimaryPort=3306; PrimaryServerId=1; PrimaryUuid='98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef'; Database='my_new_board_db'; MySqlVersion='8.4.11'; ExpectedTables=22; Files=$files }
    $manifestPath = Join-Path $bundle 'manifest.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 5), $utf8)
    $source = [PSCustomObject]@{
        Id='source'; Name='/mysql-lab'; Image='sha256:fixed84'
        Config=[PSCustomObject]@{Cmd=@('mysqld')}
        State=[PSCustomObject]@{Running=$true; ExitCode=0}
        HostConfig=[PSCustomObject]@{NetworkMode='bridge'; RestartPolicy=[PSCustomObject]@{Name='unless-stopped'}; PortBindings=[PSCustomObject]@{'3306/tcp'=@([PSCustomObject]@{HostIp=''; HostPort='3306'})}}
        Mounts=@([PSCustomObject]@{Type='volume'; Name='anonymous-original'; Destination='/var/lib/mysql'; RW=$true})
    }
    $global:ReplicaMock = @{Containers=@{source=$source}; Calls=[Collections.Generic.List[object]]::new(); Files=@{}; Sql=[Collections.Generic.List[object]]::new(); Hash=(Get-FileHash $manifestPath).Hash; BadStop=$false; RootFailure=''; TlsFailure=$false; EmptyGtid=$false; Shared=$false; BusyPort=$false}
    $path
}
function global:Get-NetTCPConnection { param($State,$LocalPort,$ErrorAction) if ($global:ReplicaMock.BusyPort) { 'busy' } }
function global:docker {
    $c = @($args)
    $m = $global:ReplicaMock
    $global:LASTEXITCODE = 0
    $m.Calls.Add($c)
    switch ($c[0]) {
        'inspect' {
            if ($c -contains '--format') { 'fixture status'; return }
            $obj = $m.Containers[$c[1]]
            if ($null -eq $obj) { $obj = @($m.Containers.Values | Where-Object Name -eq ('/' + $c[1]))[0] }
            ConvertTo-Json -InputObject @($obj) -Depth 9 -Compress
            return
        }
        'ps' {
            $filter = $c[[array]::IndexOf($c,'--filter')+1]
            if ($filter -like 'name=*') { return }
            foreach ($obj in $m.Containers.Values) {
                if (-not $obj.State.Running) { continue }
                if (($filter -like 'volume=*' -and $obj.Mounts[0].Name -eq $filter.Substring(7)) -or ($filter -eq 'publish=3306' -and $obj.HostConfig.NetworkMode -eq 'bridge')) { $obj.Id }
            }
            if ($m.Shared -and $filter -like 'volume=*') { 'foreign-writer' }
            return
        }
        'cp' { $m.Files[$c[2]] = [IO.File]::ReadAllText($c[1]); return }
        'exec' {
            if ($c -contains '-it') {
                $id = $c[2]
                $sql = $m.Files[$id + ':' + $c[-1]]
                $m.Sql.Add([PSCustomObject]@{Id=$id; Text=$sql; File=$c[-1]})
                # Model MySQL error 3056, which the earlier orchestration mock missed.
                if ($sql -match "SOURCE_PASSWORD=''([^']*)''" -and $Matches[1].Length -gt 32) { $global:LASTEXITCODE=1; return }
                if ($m.RootFailure -and $c[-1].EndsWith('/' + $m.RootFailure + '.sql')) { $global:LASTEXITCODE=1 }
            }
            elseif ($c -contains 'mysql') {
                if ($m.TlsFailure) { $global:LASTEXITCODE=1; return }
                'loop_uuid=98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef'
                $hex = ''
                if (-not $m.EmptyGtid) { $hex = '39386534303966622D613563362D313166312D386263312D3966316161336532383465663A312D32' }
                'loop_gtid_hex=' + $hex
            }
            return
        }
        'update' { $obj=$m.Containers[$c[-1]]; $obj.HostConfig.RestartPolicy.Name=$c[1].Substring(10); return }
        'stop' { $obj=$m.Containers[$c[-1]]; $obj.State.Running=$false; if ($m.BadStop) { $obj.State.ExitCode=137 }; return }
        'volume' { return }
        'run' { return }
        'rename' { $m.Containers[$c[1]].Name='/' + $c[2]; return }
        'create' {
            $name = $c[[array]::IndexOf($c,'--name')+1]
            $id = 'candidate'
            if ($name -eq 'mysql-lab') { $id='production' }
            $volumeArg=$c[[array]::IndexOf($c,'--mount')+1]
            $volume=($volumeArg -split ',source=')[1].Split(',')[0]
            $network=$c[[array]::IndexOf($c,'--network')+1]
            $imageIndex=[array]::IndexOf($c,'sha256:fixed84')
            $cmd=@($c[($imageIndex+1)..($c.Count-1)])
            $m.Containers[$id]=[PSCustomObject]@{
                Id=$id; Name=('/'+$name); Image='sha256:fixed84'; Config=[PSCustomObject]@{Cmd=$cmd}
                State=[PSCustomObject]@{Running=$false; ExitCode=0}
                HostConfig=[PSCustomObject]@{NetworkMode=$network; RestartPolicy=[PSCustomObject]@{Name='no'}; PortBindings=[PSCustomObject]@{'3306/tcp'=@([PSCustomObject]@{HostIp='0.0.0.0';HostPort='3306'})}}
                Mounts=@([PSCustomObject]@{Type='volume';Name=$volume;Destination='/var/lib/mysql';RW=$true})
            }
            $id; return
        }
        'start' { $m.Containers[$c[1]].State.Running=$true; return }
        default { throw ('Unexpected mock: '+$c[0]) }
    }
}
function Run-Step([string]$Path,[string]$Action) { & $tool -RepositoryPath $Path -Action $Action -ManifestSha256 $global:ReplicaMock.Hash }
function Expect-Failure([string]$Path,[string]$Action,[string]$Expected) {
    $message=''
    try { Run-Step $Path $Action } catch { $message=$_.Exception.Message }
    Assert-Test ($message -like ('*'+$Expected+'*')) ('Expected '+$Expected+'; got '+$message)
}
try {
    $p=New-Case 'bad-manifest'; $global:ReplicaMock.Hash='b'*64
    Expect-Failure $p Stage 'Manifest SHA256'
    Assert-Test ($global:ReplicaMock.Calls.Count -eq 0) 'Bad manifest reached Docker.'
    $p=New-Case 'bad-file'; [IO.File]::AppendAllText((Join-Path $p '.secrets/mysql84-replication/incoming/pc2-transfer/snapshot.sql'),'changed')
    Expect-Failure $p Stage 'integrity'
    Assert-Test ($global:ReplicaMock.Calls.Count -eq 0) 'Bad dump reached Docker.'
    Write-Host 'PASS: altered manifest and altered snapshot blocked before Docker'

    $p=New-Case 'bad-mount'; $global:ReplicaMock.Containers.source.Mounts[0].Destination='/other'
    Expect-Failure $p Stage 'Unexpected data mount'
    Assert-Test ($global:ReplicaMock.Sql.Count -eq 0) 'Wrong mount reached SQL.'
    $p=New-Case 'shared'; $global:ReplicaMock.Shared=$true
    Expect-Failure $p Stage 'shared use'
    Assert-Test ($global:ReplicaMock.Sql.Count -eq 0) 'Shared volume reached SQL.'
    Write-Host 'PASS: wrong mount and shared original rejected'

    $p=New-Case 'guard'; $global:ReplicaMock.RootFailure='source-preflight'
    Expect-Failure $p Stage 'Docker exec failed'
    Assert-Test (@($global:ReplicaMock.Calls | Where-Object { $_[0] -eq 'stop' }).Count -eq 0) 'SQL identity failure stopped original.'
    $p=New-Case 'unclean'; $global:ReplicaMock.BadStop=$true
    Expect-Failure $p Stage 'stop cleanly'
    Assert-Test (@($global:ReplicaMock.Calls | Where-Object { $_[0] -eq 'run' }).Count -eq 0) 'Unclean data was copied.'
    Write-Host 'PASS: failed SQL guard and unclean shutdown prevent copy'

    $p=New-Case 'success'
    Run-Step $p Stage
    Expect-Failure $p Stage 'already exist'
    Run-Step $p Restore
    $restore=@($global:ReplicaMock.Sql | Where-Object File -like '*/restore.sql')[0]
    Assert-Test ($restore.Id -eq 'candidate' -and $restore.Text.Contains('RESET BINARY LOGS AND GTIDS;') -and $restore.Text.Contains('SET PERSIST super_read_only = ON;')) 'Restore isolation or protection missing.'
    $copy=@($global:ReplicaMock.Calls | Where-Object { $_[0] -eq 'run' })[0]
    Assert-Test (($copy -join ' ').Contains('source=anonymous-original,target=/from,readonly')) 'Original copy mount is writable.'
    $global:ReplicaMock.BusyPort=$true
    Expect-Failure $p Activate '3306 is busy'
    Assert-Test ($global:ReplicaMock.Containers.source.Name -eq '/mysql-lab') 'Busy port renamed original.'
    $global:ReplicaMock.BusyPort=$false
    Run-Step $p Activate
    Expect-Failure $p Activate 'requires the restored'
    $global:ReplicaMock.TlsFailure=$true
    $before=$global:ReplicaMock.Sql.Count
    Expect-Failure $p Start 'Docker exec failed'
    Assert-Test ($before -eq $global:ReplicaMock.Sql.Count) 'TLS failure reached channel SQL.'
    $global:ReplicaMock.TlsFailure=$false
    Run-Step $p Start
    $start=@($global:ReplicaMock.Sql | Where-Object File -like '*/start-replication.sql')[0].Text
    Assert-Test ($start.Contains('SOURCE_SSL_VERIFY_SERVER_CERT=1') -and $start.Contains('SOURCE_AUTO_POSITION=1') -and $start.Contains('SOURCE_SSL_CERT=')) 'Secure auto-position channel missing.'
    Assert-Test ($start -match "SOURCE_PASSWORD=''([^']*)''") 'Channel password missing.'
    $channelPassword = $Matches[1]
    Assert-Test ($channelPassword -ceq ('Lp9!' + ('a'*28)) -and $channelPassword.Length -eq 32) 'Legacy bundle did not yield the repaired PC1 password.'
    $clientFile = Join-Path $p '.secrets/mysql84-replication/pc2/primary-client.cnf'
    Assert-Test ([IO.File]::ReadAllText($clientFile).Contains('password=' + $channelPassword + "`n")) 'TLS probe still uses old password.'
    # Retry exactly from the failure stage reported on PC2, without restoring or activating again.
    $stateFile = Join-Path $p '.secrets/mysql84-replication/pc2/state.json'
    $retryState = Get-Content $stateFile -Raw | ConvertFrom-Json
    $retryState.Stage = 'replication-starting'
    [IO.File]::WriteAllText($stateFile, ($retryState | ConvertTo-Json -Depth 8), $utf8)
    $before = $global:ReplicaMock.Calls.Count
    Run-Step $p Start
    $newCalls = @($global:ReplicaMock.Calls | Select-Object -Skip $before)
    Assert-Test (@($newCalls | Where-Object { $_[0] -in @('run','create','rename','stop') }).Count -eq 0) 'Start retry repeated restore/activation operations.'
    $global:ReplicaMock.RootFailure='verify-replication'
    Expect-Failure $p Verify 'Docker exec failed'
    Assert-Test ($global:ReplicaMock.Containers.production.HostConfig.RestartPolicy.Name -eq 'no') 'Failed verify enabled automatic restart.'
    $global:ReplicaMock.RootFailure=''
    Run-Step $p Verify
    $state=Get-Content (Join-Path $p '.secrets/mysql84-replication/pc2/state.json') -Raw | ConvertFrom-Json
    Assert-Test ($state.Stage -eq 'replica-ready') 'Ready state missing.'
    Assert-Test (-not $global:ReplicaMock.Containers.source.State.Running -and $global:ReplicaMock.Containers.source.Mounts[0].Name -eq 'anonymous-original') 'Original not preserved.'
    Assert-Test ($global:ReplicaMock.Containers.production.Config.Cmd -contains '--replicate-do-db=my_new_board_db') 'Durable app DB filter missing.'
    Assert-Test ($global:ReplicaMock.Containers.production.HostConfig.RestartPolicy.Name -eq 'unless-stopped') 'Restart policy missing.'
    Assert-Test (-not (($global:ReplicaMock.Calls | ForEach-Object { $_ -join ' ' }) -join "`n").Contains('Lp9!')) 'Credential leaked into Docker arguments.'
    $global:ReplicaMock.EmptyGtid=$true
    Run-Step $p Verify
    Run-Step $p Status
    Write-Host 'PASS: complete clone/restore/activate/TLS/start/GTID verify, repeat guards, empty GTID and secret handling'

    $p=New-Case 'wrong-candidate'; Run-Step $p Stage
    $global:ReplicaMock.Containers.candidate.Mounts[0].Name='anonymous-original'
    $before=$global:ReplicaMock.Sql.Count
    Expect-Failure $p Restore 'Unexpected data mount'
    Assert-Test ($before -eq $global:ReplicaMock.Sql.Count) 'Unsafe candidate reached destructive SQL.'
    Write-Host 'PASS: candidate on original volume cannot restore'

    $p=New-Case 'new-32-character-bundle'
    $bundle=Join-Path $p '.secrets/mysql84-replication/incoming/pc2-transfer'
    $credentialFile=Join-Path $bundle 'replication-password'
    [IO.File]::WriteAllText($credentialFile, ('Lp9!' + ('b'*28)), $utf8)
    $manifestFile=Join-Path $bundle 'manifest.json'
    $manifest=Get-Content $manifestFile -Raw | ConvertFrom-Json
    $entry=@($manifest.Files | Where-Object Path -eq 'replication-password')[0]
    $entry.Length=(Get-Item $credentialFile).Length
    $entry.Sha256=(Get-FileHash $credentialFile).Hash
    [IO.File]::WriteAllText($manifestFile, ($manifest | ConvertTo-Json -Depth 6), $utf8)
    $global:ReplicaMock.Hash=(Get-FileHash $manifestFile).Hash
    Run-Step $p Stage
    Run-Step $p Restore
    Assert-Test ([IO.File]::ReadAllText((Join-Path $p '.secrets/mysql84-replication/pc2/primary-client.cnf')).Contains('password=Lp9!' + ('b'*28) + "`n")) 'New 32-character credential changed.'
    Write-Host 'PASS: 32-character SOURCE_PASSWORD boundary, legacy Start retry and new bundle compatibility'
    Write-Host 'All replica orchestration tests passed (Docker/MySQL simulated; real PC2 validation still required).'
}
finally {
    Remove-Item Function:\docker -ErrorAction SilentlyContinue
    Remove-Item Function:\Get-NetTCPConnection -ErrorAction SilentlyContinue
    # Only remove this test run after validating its resolved temporary location.
    $resolved=[IO.Path]::GetFullPath($testRoot)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path $resolved -Leaf) -like 'loop-replica-tests-*') { Remove-Item -LiteralPath $resolved -Recurse -Force }
    Remove-Variable ReplicaMock -Scope Global -ErrorAction SilentlyContinue
}
