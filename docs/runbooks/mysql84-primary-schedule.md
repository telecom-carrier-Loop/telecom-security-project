# PC2 Primary 예약 백업·Discord 감시 비활성 준비

2026-10-28 작성. **현재 PC2는 Replica다. 이 절차는 승격하거나 기존 예약을 끄지 않는다.** 코드와 모의시험을 준비했으며 아래 현장 등록·시험 전송은 아직 미확인이다.

현재 확인: Replica 사전검사 25테이블 PASS, Primary 검사 BACKUP_PRIMARY_NOT_READY/종료 1. 기존 1시간 백업과 5분 Discord 감시는 Ready다. 새 작업은 다른 이름·경로로 Disabled 등록한다. Primary 실제 백업·복원과 예약 실행을 검증하기 전에 정상 감시로 표시하지 않는다.

## 1. 새 도구를 별도 폴더에 받기 — PC2의 기존 Windows 사용자

```powershell
$loopRepo = Join-Path $env:USERPROFILE 'telecom-security-project'
git -C "$loopRepo" fetch origin
if ($LASTEXITCODE -ne 0) { throw 'Git fetch failed.' }
$loopPrimaryRef = 'origin/pc2-primary-backup-20261028'
$loopPrepareDir = Join-Path $env:TEMP ('loop-primary-prepare-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $loopPrepareDir
$loopBundle = Join-Path $loopPrepareDir 'tools.zip'
$loopFiles = @(
    'infrastructure/tools/mysql84-backup.ps1'
    'infrastructure/tools/mysql84-backup-schedule.ps1'
    'infrastructure/tools/mysql84-backup-discord.ps1'
)
git -C "$loopRepo" archive --format=zip --output="$loopBundle" "$loopPrimaryRef" @loopFiles
if ($LASTEXITCODE -ne 0) { throw 'Tool archive failed.' }
Expand-Archive -LiteralPath $loopBundle -DestinationPath $loopPrepareDir
$loopPrimaryBackup = Join-Path $loopPrepareDir 'infrastructure/tools/mysql84-backup.ps1'
$loopPrimarySchedule = Join-Path $loopPrepareDir 'infrastructure/tools/mysql84-backup-schedule.ps1'
$loopPrimaryMonitor = Join-Path $loopPrepareDir 'infrastructure/tools/mysql84-backup-discord.ps1'
foreach ($loopFile in @($loopPrimaryBackup,$loopPrimarySchedule,$loopPrimaryMonitor)) {
    Unblock-File -LiteralPath $loopFile
    $loopTokens=$null; $loopErrors=$null
    $null=[Management.Automation.Language.Parser]::ParseFile($loopFile,[ref]$loopTokens,[ref]$loopErrors)
    if ($loopErrors.Count -gt 0) { throw 'Downloaded script syntax error.' }
}
```

git archive는 파일 인코딩과 BOM을 보존한다. 기존 설치 복사본을 덮어쓰지 않는다. Prepare는 검사한 원본을 고정 설치 폴더로 복사하고 해시를 기록하므로 이후 TEMP 정리의 영향을 받지 않는다.

## 2. 기존 Replica의 최신 백업 복원 확인

Prepare는 기존 Replica latest.json의 restore-verified 상태를 요구한다. 시간 예약이 그사이에 새 덤프를 만들어 backup-ready라면 그 덤프를 격리 복원한다. 기존 설치 도구를 사용한다.

```powershell
$loopLatestPath = Join-Path $loopRepo '.secrets/backups/mysql84/pc2/latest.json'
$loopLatest = Get-Content -LiteralPath $loopLatestPath -Raw | ConvertFrom-Json
if ($loopLatest.Stage -eq 'backup-ready') {
    $loopInstalledBackup = Join-Path $loopRepo '.secrets/backups/mysql84/pc2/scheduler/mysql84-backup.ps1'
    powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopInstalledBackup" -RepositoryPath "$loopRepo" -Action RestoreTest
    if ($LASTEXITCODE -ne 0) { throw 'Replica isolated restore failed.' }
}
$loopLatest = Get-Content -LiteralPath $loopLatestPath -Raw | ConvertFrom-Json
if ($loopLatest.Stage -ne 'restore-verified') { throw 'Inspect the existing backup/restore state before Prepare.' }
```

다른 실패·진행 중 상태이면 중단하고 Status를 확인한다. 복원은 격리 컨테이너에만 수행한다.

## 3. Primary 예약 백업 준비

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopPrimarySchedule" -RepositoryPath "$loopRepo" -BackupToolPath "$loopPrimaryBackup" -SourceRole Primary -Action Prepare
if ($LASTEXITCODE -ne 0) { throw 'Primary schedule preparation failed.' }
```

기대값은 Primary backup task prepared DISABLED와 ActivationPending True다. 작업 이름은 `Loop-MySQL84-PC2-Primary-Hourly-Backup`, 고정 경로는 `.secrets/backups/mysql84/pc2-primary/scheduler/`다. 기존 DPAPI 백업 계정을 사용하며 root 비밀번호를 저장하지 않는다.

Prepare는 기존 Replica의 복원 성공을 준비 전제로 검사하며 Primary 복원 성공으로 간주하지 않는다. 준비 중에는 Run/Test/Repair 활성화를 차단한다. 실제 Primary 백업·복원 검증 후 명시적 Install로 활성화한다. 같은 이름의 다른 작업이 이미 있으면 덮어쓰지 않는다.

## 4. Primary Discord 감시 준비

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopPrimaryMonitor" -RepositoryPath "$loopRepo" -SourceRole Primary -Action Prepare
if ($LASTEXITCODE -ne 0) { throw 'Primary monitor preparation failed.' }
```

기대값은 Primary Discord monitor prepared DISABLED다. 작업 이름은 `Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor`, 고정 경로는 `.secrets/backups/mysql84/pc2-primary/discord-monitor/`다. 기존 Windows 사용자의 암호화 webhook 파일을 별도 보호 폴더로 복사하며 원본은 변경하지 않는다. Prepare는 외부 메시지를 보내지 않는다.

## 5. 시험 메시지 한 번 전송

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopPrimaryMonitor" -RepositoryPath "$loopRepo" -SourceRole Primary -Action TestAlert
if ($LASTEXITCODE -ne 0) { throw 'Discord TEST delivery failed.' }
```

Discord에서 `[TEST] PC2 MySQL Primary` 메시지를 확인한다. 실제 실패를 만들거나 백업 작업을 실행하는 시험은 아니다. webhook URL·DB 비밀번호를 대화나 명령 인수에 넣지 않는다.

## 6. 최종 상태

```powershell
Get-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Hourly-Backup','Loop-MySQL84-PC2-Backup-Discord-Monitor','Loop-MySQL84-PC2-Primary-Hourly-Backup','Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor' | Select-Object TaskName,State
```

| 작업 | 현재 기대 상태 |
|---|---|
| 기존 Replica 시간 백업 | Ready 또는 실행 중 Running |
| 기존 Replica Discord 감시 | Ready 또는 실행 중 Running |
| 새 Primary 시간 백업 | Disabled |
| 새 Primary Discord 감시 | Disabled |

현재 단계는 준비 완료다. Primary 백업 운영은 아직 시작하지 않는다. Windows 사용자 로그인·PC·Docker가 유지되어야 예약이 동작한다. 새 작업의 LastTaskResult가 0x41303이면 아직 실행하지 않았다는 뜻이며 성공 코드가 아니다.

## 7. 이후 계획 전환 단계 — 지금 실행하지 않음

1. 기존 Replica 예약·감시가 실행 중이지 않은지 확인 후 둘 다 비활성화한다. 실행 중 작업을 강제 종료하지 않는다.
2. 앱·자동화 쓰기를 중지하고 기존 Primary의 쓰기를 차단한 뒤 최종 GTID 동기화와 승격을 별도 절차로 수행한다. PC1 k3s 제어부는 유지한다.
3. 역할별 백업 도구의 Primary BackupSaved와 Primary RestoreTest를 수행한다. 실패 시 예약을 활성화하지 않는다.
4. Primary 예약을 Install로 활성화한 후 Test로 실제 예약 백업의 새 성공 기록을 확인한다. Primary 기록에는 SourceRole=Primary가 있어야 한다.
5. 같은 worker의 TestAlert 확인 기록이 24시간 이내인지 확인하고 Primary 감시를 Install로 활성화한다. Primary 성공 기록·백업 파일·작업 상태가 정상이어야 한다. 준비된 작업의 계정·권한·명령·주기 변경은 거절한다.
6. 앱 DB_HOST와 PC2 전용 DB_PASSWORD를 전환하고 읽기·쓰기·로그인·복제·복귀 계획을 검증한다. 앱의 비밀번호는 PC1과 다를 수 있다.

준비된 작업을 Enable-ScheduledTask로 직접 활성화해도 ActivationPending이 해제되지 않으므로 정식 Install 단계를 우회하지 않는다. 전환을 중단하면 Primary 두 작업은 Disabled로 유지하고 Replica를 계속 운영한다. PC1 전체 중단 시험에는 단일 제어부·CoreDNS·DB 복귀에 대한 추가 준비가 필요하다.

## 코드 검증 범위

기존 예약 백업 회귀, 기존 Discord 알림·중복 억제·복구·전송 실패 회귀, 새 Primary 비활성 준비·실행 차단·역할 검증·작업 변경 거절·검증 후 활성화·역할별 경보·복구·Replica 분리 모의시험을 통과했다. 실제 학원 작업 등록·Discord 전송·Primary DB 전환은 대신 수행하지 않았다.

근거: [비활성예약설정](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset), [역할별백업](mysql84-primary-backup.md).
