param([string]$BuildRoot = (Join-Path $env:USERPROFILE 'Downloads'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
function Check-Native([string]$Message) {
    if ($LASTEXITCODE -ne 0) { throw $Message }
}
$stamp = Get-Date -Format 'yyyyMMddHHmmss'
$source = Join-Path $BuildRoot "telecom-clean-source-$stamp"
$release = Join-Path $BuildRoot "telecom-clean-release-$stamp"
if ((Test-Path -LiteralPath $source) -or (Test-Path -LiteralPath $release)) {
    throw 'Destination exists. Run again with a new timestamp.'
}
$dockerOs = docker info --format '{{.OSType}}'
Check-Native 'Start Docker Desktop first.'
if (($dockerOs -join '').Trim() -ne 'linux') { throw 'Linux containers are required.' }
git clone --no-checkout --filter=blob:none --branch main --single-branch https://github.com/telecom-carrier-Loop/telecom-security-project.git $source
Check-Native 'Git clone failed.'
git -C $source sparse-checkout set --no-cone '/backend/' '/frontend/' '/infrastructure/docker/' '/infrastructure/tools/webapi-release/release.py' '/infrastructure/tools/k3s-admin-access.py' '/infrastructure/tools/loop-client-ip-test.py'
Check-Native 'Cannot select build directories.'
git -C $source fetch origin main
Check-Native 'Git fetch failed.'
$commit = (git -C $source rev-parse origin/main)
Check-Native 'Cannot read source revision.'
$commit = ($commit -join '').Trim()
if ($commit -notmatch '^[0-9a-f]{40}$') { throw 'Unexpected revision.' }
git -C $source checkout --detach $commit
Check-Native 'Cannot select source revision.'
$dirty = @(git -C $source status --porcelain)
Check-Native 'Git status failed.'
if ($dirty.Count -ne 0) { throw 'The new checkout is not clean.' }
New-Item -ItemType Directory -Path $release | Out-Null
foreach ($part in @('backend', 'frontend')) {
    $ignore = Join-Path $source "$part\.dockerignore"
    if (-not (Test-Path -LiteralPath $ignore -PathType Leaf)) { throw "Missing $ignore" }
    Copy-Item -LiteralPath $ignore -Destination (Join-Path $release "$part.dockerignore.before")
    [IO.File]::AppendAllText($ignore, "`n.env`n.env.*`n**/.env`n**/.env.*`n", [Text.UTF8Encoding]::new($false))
}
$tag = 'k3s-' + $commit.Substring(0, 12) + '-' + $stamp
$backend = 'docker.io/library/telecom-backend:' + $tag
$frontend = 'docker.io/library/telecom-frontend:' + $tag
docker build --platform linux/amd64 --label "org.opencontainers.image.revision=$commit" -f (Join-Path $source 'infrastructure\docker\backend\Dockerfile') -t $backend (Join-Path $source 'backend')
Check-Native 'Backend build failed.'
$check = @'
from pathlib import Path
files = [p for p in Path('/app').rglob('*') if p.is_file() and (p.name == '.env' or p.name.startswith('.env.'))]
if files:
    raise SystemExit('STOP: env files found in backend image')
print('PASS: backend image contains no env files')
'@
$check | docker run --rm -i --network none --entrypoint python $backend -
Check-Native 'Backend image env exclusion check failed.'
docker build --platform linux/amd64 --label "org.opencontainers.image.revision=$commit" -f (Join-Path $source 'infrastructure\docker\frontend\Dockerfile') -t $frontend (Join-Path $source 'frontend')
Check-Native 'Frontend build failed.'
$backendId = (docker image inspect $backend --format '{{.Id}}')
Check-Native 'Cannot inspect backend image.'
$frontendId = (docker image inspect $frontend --format '{{.Id}}')
Check-Native 'Cannot inspect frontend image.'
$archive = Join-Path $release 'telecom-app.tar'
docker image save --output $archive $backend $frontend
Check-Native 'Image archive failed.'
$metadata = @{
    source_commit = $commit; tag = $tag
    backend = $backend; frontend = $frontend
    backend_id = ($backendId -join '').Trim()
    frontend_id = ($frontendId -join '').Trim()
    archive_sha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
}
[IO.File]::WriteAllText((Join-Path $release 'release.json'), ($metadata | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
# Package validators from the same clean source revision as the images.
Copy-Item -LiteralPath (Join-Path $source 'infrastructure\tools\webapi-release\release.py') -Destination (Join-Path $release 'release.py')
Copy-Item -LiteralPath (Join-Path $source 'infrastructure\tools\k3s-admin-access.py') -Destination (Join-Path $release 'k3s-admin-access.py')
Copy-Item -LiteralPath (Join-Path $source 'infrastructure\tools\loop-client-ip-test.py') -Destination (Join-Path $release 'loop-client-ip-test.py')
$remote = "/home/loop/telecom-releases/$tag"
foreach ($vm in @('192.168.7.185', '192.168.7.100')) {
    ssh "loop@$vm" "install -d -m 700 $remote"
    Check-Native "Cannot prepare VM: $vm"
    scp $archive (Join-Path $release 'release.json') (Join-Path $release 'release.py') (Join-Path $release 'k3s-admin-access.py') (Join-Path $release 'loop-client-ip-test.py') "loop@${vm}:${remote}/"
    Check-Native "Transfer failed: $vm"
    ssh "loop@$vm" "printf '%s\n' '$remote' > /home/loop/.telecom-clean-release"
    Check-Native "Cannot save release pointer: $vm"
}
Write-Host "SOURCE: $source"
Write-Host "COMMIT: $commit"
Write-Host "TAG: $tag"
Write-Host "PACKAGE: $release"
Write-Host 'Upload completed. Run import on BOTH Ubuntu VMs.'
Write-Host 'On PC1 Ubuntu: use apply-images to keep current env, or apply to update Ubuntu env files.'
