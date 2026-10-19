# Integration test: two isolated local Compose projects, never the shared PCs.
# Stops/removes only its own containers/network; retains volumes and ignored secrets.
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$controller = Join-Path $root 'infrastructure/tools/shared-pc.ps1'
$id = [guid]::NewGuid().ToString('N').Substring(0,8)
$directory = Join-Path $root ".data/shared-pc-test-$id"
$secretDirectory = Join-Path $root ".secrets/shared-pc-test-$id"
$environmentFile = Join-Path $directory 'settings.env'
$networkName = "telecom-infra-test-$id"
$primaryProject = "telecom-infra-test-primary-$id"
$replicaProject = "telecom-infra-test-replica-$id"
$primaryOverride = Join-Path $directory 'pc1.yaml'
$replicaOverride = Join-Path $directory 'pc2.yaml'
$utf8 = New-Object Text.UTF8Encoding($false)
[IO.Directory]::CreateDirectory($directory) | Out-Null
[IO.File]::WriteAllText($environmentFile,"PRIMARY_IP=127.0.0.1`nREPLICA_IP=127.0.0.1`nPRIMARY_PORT=3306`n",$utf8)
[IO.File]::WriteAllText($primaryOverride,@"
services:
  mysql:
    ports: !override ['127.0.0.1:13318:3306']
    networks:
      default:
        aliases: [mysql-primary.telecom.test]
networks:
  default:
    external: true
    name: $networkName
"@,$utf8)
[IO.File]::WriteAllText($replicaOverride,@"
services:
  mysql:
    extra_hosts: !reset []
networks:
  default:
    external: true
    name: $networkName
"@,$utf8)
$primary = @{ Role='pc1'; EnvironmentFile=$environmentFile; SecretDirectory=$secretDirectory; ProjectName=$primaryProject; ComposeOverride=$primaryOverride }
$replica = @{ Role='pc2'; EnvironmentFile=$environmentFile; SecretDirectory=$secretDirectory; ProjectName=$replicaProject; ComposeOverride=$replicaOverride }
$listener = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,13318)
try { $listener.Start() } finally { $listener.Stop() }
docker network create $networkName | Out-Null
if ($LASTEXITCODE -ne 0) { throw 'Test network creation failed' }
try {
    Write-Output "TEST_DIRECTORY=$directory"
    Write-Output "TEST_SECRET_DIRECTORY=$secretDirectory"
    & $controller -Action prepare-primary @primary
    & $controller -Action prepare-replica @replica -TransferDirectory (Join-Path $secretDirectory 'pc2-transfer')
    & $controller -Action up @primary
    & $controller -Action bootstrap-primary @primary
    & $controller -Action up @replica
    & $controller -Action connect-replica @replica
    & $controller -Action connect-replica @replica
    $probeOutput = & $controller -Action write-probe @primary 6>&1 | Out-String
    if ($probeOutput -notmatch 'PROBE_ID=([a-f0-9-]{36})') { throw 'Missing probe ID' }
    $probeId = $matches[1]
    & $controller -Action verify @replica -ProbeId $probeId
    # The same valid credentials without the PC2 client certificate must fail.
    $replicaContainer = "$replicaProject-mysql-1"
    $client = 'read -r MYSQL_PWD; export MYSQL_PWD; exec mysql --protocol=TCP -h mysql-primary.telecom.test -utelecom_repl --ssl-mode=VERIFY_IDENTITY --ssl-ca=/run/mysql-tls/ca.crt --connect-timeout=5 --batch --skip-column-names -e "SELECT 1"'
    $replicationPassword = [IO.File]::ReadAllText((Join-Path $secretDirectory 'pc2/replication-password'))
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $negative = @($replicationPassword | docker exec -i $replicaContainer sh -c $client 2>&1) | Out-String
        $negativeCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($negativeCode -eq 0 -or $negative -notmatch 'ERROR 1045') { throw 'Missing-client-certificate connection was not rejected.' }
    Write-Output 'PASS: replication password without the dedicated client certificate rejected.'
    $networkInfo = docker inspect "$primaryProject-mysql-1" --format '{{json .NetworkSettings.Networks}}' | ConvertFrom-Json
    $primaryContainerIp = $networkInfo.$networkName.IPAddress
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $wrongName = @(docker exec $replicaContainer mysql --protocol=TCP -h $primaryContainerIp -utelecom_repl --ssl-mode=VERIFY_IDENTITY --ssl-ca=/run/mysql-tls/ca.crt --connect-timeout=5 -e 'SELECT 1' 2>&1) | Out-String
        $wrongNameCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $oldPreference }
    if ($wrongNameCode -eq 0 -or $wrongName -notmatch 'ERROR 2026') { throw 'Mismatched TLS server identity was not rejected.' }
    Write-Output 'PASS: TLS server name mismatch rejected.'
    docker compose --env-file $environmentFile -p $replicaProject -f (Join-Path $root 'infrastructure/docker/compose/shared-pc/pc2.yaml') -f $replicaOverride restart mysql
    if ($LASTEXITCODE -ne 0) { throw 'Restart failed' }
    # Do not call connect-replica: prove the existing channel resumes by itself.
    & $controller -Action verify @replica -ProbeId $probeId
    & $controller -Action status @replica
    Write-Output 'PASS: clean bootstrap, repeated connect, GTID probe, TLS negative checks, read-only rejection, automatic replica restart recovery.'
} finally {
    # Only this invocation's uniquely named projects; never delete volumes.
    $env:SHARED_SECRET_ROOT = $secretDirectory.Replace('\','/')
    foreach ($item in @(@($primaryProject,'pc1',$primaryOverride),@($replicaProject,'pc2',$replicaOverride))) {
        docker compose --env-file $environmentFile -p $item[0] -f (Join-Path $root "infrastructure/docker/compose/shared-pc/$($item[1]).yaml") -f $item[2] down
    }
    docker network rm $networkName
    Remove-Item Env:SHARED_SECRET_ROOT -ErrorAction SilentlyContinue
}
