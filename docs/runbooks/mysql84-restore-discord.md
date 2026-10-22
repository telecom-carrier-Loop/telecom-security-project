# 최신 백업 복원 시험과 Discord 실패 알림

모든 명령은 **PC2 Windows의 기존 백업 사용자**로 연 **Windows PowerShell 5.1**에서 실행한다. Ubuntu SSH 창이나 PC1에서 실행하지 않는다. 기존 `mysql-lab`, 복제 설정, 데이터 볼륨과 1시간 백업 예약은 유지한다. 아래 명령은 현장에서 사용자가 실행할 절차이며, 문서 작성 PC에서 실제 DB 복원·Discord 전송·예약 등록을 완료한 기록은 아니다.

## 1. 설치된 백업 도구와 실행 시각 확인

새 PowerShell 창을 열고 다음 블록을 실행한다.

```powershell
$ErrorActionPreference = 'Stop'
$loopRepo = 'C:/Users/user/telecom-security-project'
$loopBackupRoot = Join-Path $loopRepo '.secrets/backups/mysql84/pc2'
$loopSchedule = Join-Path $loopBackupRoot 'scheduler/mysql84-backup-schedule.ps1'
$loopBackup = Join-Path $loopBackupRoot 'scheduler/mysql84-backup.ps1'

powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Status
if ($LASTEXITCODE -ne 0) { throw '예약 상태 검사 실패. 다음 단계로 진행하지 마세요.' }

$loopTask = Get-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Hourly-Backup'
$loopTaskInfo = Get-ScheduledTaskInfo -TaskName 'Loop-MySQL84-PC2-Hourly-Backup'
if ($loopTask.State -ne 'Ready') { throw '기존 백업 작업이 Ready일 때 진행하세요. 실행 중이면 완료를 기다리세요.' }
if ($loopTaskInfo.LastTaskResult -ne 0) { throw '직전 백업 예약 결과가 성공이 아닙니다. 원인을 확인한 뒤 진행하세요.' }
if ($loopTaskInfo.NextRunTime -le (Get-Date).AddMinutes(15)) { throw '다음 예약까지 15분 이하입니다. 예약 백업 완료 후 이 블록부터 다시 실행하세요.' }

$loopScheduleConfig = Get-Content -LiteralPath (Join-Path $loopBackupRoot 'scheduler/config.json') -Raw | ConvertFrom-Json
if ((Get-FileHash -LiteralPath $loopBackup).Hash -ine $loopScheduleConfig.BackupSha256) { throw '설치된 백업 도구 해시가 다릅니다. 중단하세요.' }
$loopLatest = Get-Content -LiteralPath (Join-Path $loopBackupRoot 'latest.json') -Raw | ConvertFrom-Json
$loopSuccess = Get-Content -LiteralPath (Join-Path $loopBackupRoot 'scheduler/last-success.json') -Raw | ConvertFrom-Json
if ($loopLatest.Stage -notin @('backup-ready','restore-verified') -or $loopLatest.Directory -ne $loopSuccess.BackupDirectory) { throw '최신 성공한 예약 백업과 복원 대상이 일치하지 않습니다. 상태를 확인하세요.' }
$loopRestoreDir = $loopLatest.Directory
Write-Host ('복원 시험 대상: ' + $loopRestoreDir)
Write-Host ('백업 완료 UTC: ' + $loopSuccess.CompletedUtc)
Get-PSDrive -Name C | Select-Object Name,@{Name='FreeGiB';Expression={[Math]::Round($_.Free / 1GB,2)}}
docker inspect --format 'name={{.Name}} status={{.State.Status}}' mysql-lab
if ($LASTEXITCODE -ne 0) { throw 'mysql-lab 조회 실패. 중단하세요.' }
```

`mysql-lab`이 running이고 Status의 최근 실행이 success인지 확인한다. 새 복원용 MySQL에 최대 1 GiB 메모리와 별도 볼륨이 필요하므로 디스크 여유를 확인한다. 15분은 예약과 겹칠 가능성을 줄이는 여유이며 실행 시간을 보장하지 않는다. 백업·복원 도구는 같은 잠금을 사용한다. 시험이 다음 예약까지 길어지면 해당 예약이 잠금 충돌로 실패할 수 있으므로 완료 후 반드시 Status를 확인한다. 원본을 중지하거나 예약을 강제로 끄지 않는다.

## 2. 최신 성공 백업을 격리 복원

같은 PowerShell 창에서 실행한다. root 비밀번호를 다시 입력할 필요가 없다. 매번 새 백업을 만드는 `Test`와 아래 `RestoreTest`는 다른 작업이다.

```powershell
$loopRestoreTimer = [Diagnostics.Stopwatch]::StartNew()
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopBackup" -RepositoryPath "$loopRepo" -Action RestoreTest
$loopRestoreExit = $LASTEXITCODE
$loopRestoreTimer.Stop()
Write-Host ('복원 시험 전체 소요 초: ' + [Math]::Round($loopRestoreTimer.Elapsed.TotalSeconds,1))
if ($loopRestoreExit -ne 0) { throw '복원 시험 실패. 반복 실행하거나 원본을 수정하지 말고 Status를 확인하세요.' }
```

성공 시 `PASS: isolated restore verified; ... tables CHECK TABLE OK; row counts saved.`가 표시된다. 테이블 수는 현재 백업에 따라 달라지므로 22개로 고정하지 않는다. 이미 같은 덤프를 검증했다면 `This backup already passed its restore test`가 표시된다. 이 경우 새 시험이 실행된 것으로 기록하지 않는다.

도구는 덤프·manifest 해시를 검사하고, 새 시험 볼륨과 `network=none`, 공개 포트 없음, server_id 9032의 컨테이너에 복원한다. 각 테이블의 CHECK TABLE 결과와 복원 후 행 수를 기록한 뒤 **시험 컨테이너만 중지**한다. 원본 Replica를 대상으로 복원하지 않는다. 소요 시간은 격리 시험 시간이며 업무 서비스의 전체 복구 시간(RTO)을 측정한 것은 아니다. 행 수 기록은 원본과의 전체 데이터 체크섬 비교를 뜻하지 않는다.

## 3. 선택한 백업의 복원 기록과 원본 유지 확인

```powershell
$loopRestoreState = Get-Content -LiteralPath (Join-Path $loopRestoreDir 'state.json') -Raw | ConvertFrom-Json
$loopRestoreState | Select-Object Stage,Directory,TestName
if ($loopRestoreState.Stage -ne 'restore-verified') { throw '선택한 백업의 복원 완료 기록이 없습니다.' }
docker inspect --format 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}}' $loopRestoreState.TestId
docker inspect --format 'name={{.Name}} status={{.State.Status}}' mysql-lab
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Status
if ($LASTEXITCODE -ne 0) { throw '백업 예약 상태를 확인하세요.' }
```

선택한 백업의 Stage는 `restore-verified`, 시험 컨테이너는 exited/exit=0, 원본 `mysql-lab`은 running, 기존 예약은 Ready여야 한다. 시험 자료와 볼륨은 보관하며 자동 삭제하지 않는다. 이후 예약이 새 백업을 만들면 `latest.json`은 새 백업을 가리킬 수 있으므로 위처럼 선택한 디렉터리의 `state.json`을 확인한다.

## 4. Discord 웹훅 준비

Discord의 일반 텍스트 채널에서 웹훅 관리 권한이 있는 사용자가 채널 설정 → 연동(Integrations) → 웹훅(Webhooks)에서 새 웹훅을 만든다. 이름은 `Loop DB Backup`, 전송할 채널은 백업 알림 전용 채널로 지정하고 웹훅 URL을 복사한다. 포럼·미디어 채널은 이 도구의 대상이 아니다.

URL은 `https://discord.com/api/webhooks/.../...` 형식이다. **채팅·스크린샷·명령행·GitHub에 붙이지 않는다.** 아래 숨김 입력창에만 붙인다. PC2의 HTTPS 외부 통신이 허용돼야 한다. 브라우저 UI 명칭은 Discord 언어에 따라 다를 수 있다.

## 5. 새 감시 도구 받기와 웹훅 암호화 저장

같은 PC2 Windows PowerShell 창에서 실행한다. 기존 백업 도구는 교체하지 않는다. 감시 도구는 별도 파일로 내려받아 고정한 SHA256을 확인한다.

```powershell
$loopAlertSource = Join-Path $env:TEMP 'loop-mysql84-backup-discord.ps1'
$loopAlertUrl = 'https://raw.githubusercontent.com/telecom-carrier-Loop/telecom-security-project/codex/mysql84-discord-monitor-20261022/infrastructure/tools/mysql84-backup-discord.ps1'
Invoke-WebRequest -UseBasicParsing -Uri $loopAlertUrl -OutFile $loopAlertSource
if ((Get-FileHash -Algorithm SHA256 -LiteralPath $loopAlertSource).Hash -ine '1172F90BB643A170A05095C5700C4751FE9F3271AA92E619084C22183830482E') { throw '내려받은 감시 도구 해시가 다릅니다. 실행하지 마세요.' }
Unblock-File -LiteralPath $loopAlertSource
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopAlertSource" -RepositoryPath "$loopRepo" -Action SaveWebhook
if ($LASTEXITCODE -ne 0) { throw '웹훅 저장 실패. 중단하세요.' }
$loopAlert = Join-Path $loopBackupRoot 'discord-monitor/mysql84-backup-discord.ps1'
```

`Paste the Discord webhook URL ...` 안내가 나오면 URL을 붙이고 Enter를 누른다. 이 명령에는 `-NonInteractive`를 넣지 않는다. 입력은 숨겨지며 저장 자체는 메시지를 보내지 않는다.

웹훅은 기존 백업 사용자와 같은 Windows 사용자·컴퓨터에서만 복호화 가능한 DPAPI 자격 증명으로 `.secrets/backups/mysql84/pc2/discord-monitor/webhook.clixml`에 저장된다. 감시 폴더는 해당 사용자와 SYSTEM만 접근하도록 설정한다. 웹훅·로그·SQL 덤프를 Git에 추가하지 않는다. 이미 구성됐다는 오류가 나오면 파일을 지우거나 재저장하지 말고 Status를 확인한다.

## 6. 실제 Discord 시험 메시지 확인

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action TestAlert
if ($LASTEXITCODE -ne 0) { throw 'Discord 시험 전송 실패. 예약 등록 전에 연결과 웹훅을 확인하세요.' }
```

PowerShell에서 `PASS: Discord confirmed the TEST message`가 나오고 선택한 채널에 `[TEST] PC2 MySQL 백업 알림 전송 시험`과 한국 시간 전송 시각이 도착해야 한다. `wait=true`로 Discord의 저장 응답까지 확인한다. 실제 백업 실패·복원·DB 전환은 일으키지 않는다. 봇을 별도 설치하거나 DB 비밀번호를 제공할 필요는 없다.

## 7. 현재 상태 점검 후 별도 5분 감시 예약 등록

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action Check
if ($LASTEXITCODE -ne 0) { throw '현재 백업 또는 전송에 문제가 있습니다. Discord와 감시 Status를 확인하고 해결 후 등록하세요.' }
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action Install
if ($LASTEXITCODE -ne 0) { throw '감시 예약 등록 결과를 확인하세요. 중복 등록하지 마세요.' }
```

정상이면 `CHECK: healthy; delivery=not-needed`가 표시된다. 실행 중인 백업이 있으면 `pending`일 수 있으며 이를 복구 완료로 알리지 않는다. 실제 이상이 있으면 Check가 Discord에 ALERT를 보내고 오류로 종료하므로 실제 이상을 해결한 뒤 진행한다.

새 작업 이름은 `Loop-MySQL84-PC2-Backup-Discord-Monitor`다. 첫 감시는 등록 약 1분 뒤, 이후 5분마다 실행된다. 기존 `Loop-MySQL84-PC2-Hourly-Backup` 작업은 교체·수정하지 않는다. 감시 코드 고정 복사본과 SHA256을 저장하므로 Git 변경만으로 예약 코드를 자동 교체하지 않는다.

## 8. 실제 감시 예약 실행 확인

같은 창에서 아래 블록으로 수동 Check 호출과 별개인 **실제 Task Scheduler 실행**을 확인한다. 새 시험 메시지를 보내는 단계는 아니므로 정상 상태에서는 Discord가 조용한 것이 맞다.

```powershell
$loopMonitorTask = 'Loop-MySQL84-PC2-Backup-Discord-Monitor'
$loopBeforeCheck = (Get-Content -LiteralPath (Join-Path $loopBackupRoot 'discord-monitor/last-check.json') -Raw | ConvertFrom-Json).CheckedUtc
Start-ScheduledTask -TaskName $loopMonitorTask
$loopObserved = $false
for ($loopAttempt=0; $loopAttempt -lt 20; $loopAttempt++) {
    Start-Sleep -Seconds 2
    $loopCheck = Get-Content -LiteralPath (Join-Path $loopBackupRoot 'discord-monitor/last-check.json') -Raw | ConvertFrom-Json
    $loopMonitorState = Get-ScheduledTask -TaskName $loopMonitorTask
    if ($loopCheck.CheckedUtc -ne $loopBeforeCheck -and $loopMonitorState.State -ne 'Running') {
        $loopObserved = $true
        break
    }
}
if (-not $loopObserved) { throw '40초 안에 새 감시 예약 완료를 확인하지 못했습니다. Status를 확인하고 반복 실행하지 마세요.' }
$loopMonitorInfo = Get-ScheduledTaskInfo -TaskName $loopMonitorTask
if ($loopMonitorInfo.LastTaskResult -ne 0) { throw '감시 작업이 이상을 감지했거나 전송에 실패했습니다. Status와 Discord를 확인하세요.' }
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action Status
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Status
```

감시 작업 Ready/result=0, 새 CheckedUtc, healthy 또는 정상 실행 중인 백업의 pending, 기존 백업 예약 Ready 또는 정상 Running을 확인한다. 이후 첫 5분 정기 실행이 지난 다음에는 두 Status만 조회해 CheckedUtc가 다시 새로워지는지 확인한다.

## 웹훅 저장·시험 전송 후, 예약 등록 전 메시지 코드 갱신

이 절차는 웹훅 저장과 시험 전송까지만 실행했고 자동 감시 예약은 아직 등록하지 않은 경우에 사용한다. 위 5단계의 최신 파일 다운로드·SHA256 확인·Unblock-File까지 실행한 뒤, **SaveWebhook을 다시 실행하는 대신** 아래 블록을 실행한다. 기존 웹훅을 다시 입력하지 않는다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlertSource" -RepositoryPath "$loopRepo" -Action Update
if ($LASTEXITCODE -ne 0) { throw '메시지 코드 갱신 실패. 여기서 중단하세요.' }
$loopAlert = Join-Path $loopBackupRoot 'discord-monitor/mysql84-backup-discord.ps1'
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action TestAlert
if ($LASTEXITCODE -ne 0) { throw '새 버전 시험 전송 실패. 예약 등록 전에 확인하세요.' }
```

Update는 원래 사용자와 기존 설치 해시를 확인하고 감시 코드·해시만 갱신한다. 웹훅, 백업 예약·도구, DB·복제는 유지하며 실패하면 이전 코드·설정으로 되돌린다. Check 실행 중이거나 자동 감시 예약이 이미 존재하면 갱신하지 않는다. 현재 버전의 새 TestAlert 성공을 확인한 뒤 7~8단계의 예약 등록·실행 확인으로 진행한다.

## 한국 시간·실제 경과 시간 메시지

메시지의 시각은 실행 PC의 시간대 설정과 무관하게 KST(UTC+9)로 표시하고, 내부 JSON 기록은 UTC를 유지한다. 다음은 문구 설명용 예시이며 실제 현장 장애 기록이 아니다.

```text
[ALERT] PC2 MySQL 백업 이상
확인 시각: 2026-10-23 00:00:13 KST
- 2026-10-22 22:25:13 KST 마지막 백업 성공 이후 1시간 35분 0초 동안 새 백업이 성공적으로 완료되지 않았습니다. (기준: 90분)
```

```text
[ALERT] PC2 MySQL 백업 이상
확인 시각: 2026-10-22 23:27:14 KST
- 백업 작업이 2026-10-22 23:14:14 KST에 시작된 뒤 13분 0초 동안 완료되지 않았습니다. (기준: 12분)
```

12분은 미실행 시간이 아니라 실행 중인 작업의 완료 지연 기준이다. 5분 점검 주기 때문에 실제 문구에는 13분·16분 등 감지 당시 경과 시간이 표시될 수 있다. 실패 알림에는 확인 시각, 마지막 성공 시각, 최근 작업의 시작·종료 시각과 소요 시간을 표시한다. 기록이 손상돼 시각을 알 수 없으면 추측하지 않고 확인 불가로 표시한다. 정상화·시험 메시지도 한국어와 KST 시각을 사용한다.

## 알림 기준과 한계

| 조건 | 감지/전송 |
|---|---|
| last-run이 failed 또는 실행 종료 코드가 0이 아님 | 다음 5분 점검에서 ALERT |
| 백업 작업 누락·Disabled·비정상 상태 | 다음 점검에서 ALERT |
| 마지막 성공 완료 후 90분 초과 | 다음 점검에서 ALERT. 정상 1시간 주기에 30분 여유를 둠 |
| 실행 또는 running 기록이 12분 초과 | 다음 점검에서 ALERT. 기존 백업 작업 제한은 10분 |
| 상태 JSON 손상·마지막 백업 파일 누락 | ALERT |
| 같은 이상 지속 | 중복 억제, 마지막 전송 후 60분 이상이면 재알림 |
| 이상 종류 변경 | 새 ALERT |
| 이상 해소, 실행 중이 아님 | RECOVERY 1회 |
| Discord 전송 실패 | 로컬 Delivery=failed, 예약 결과 비정상. 전송 완료로 기록하지 않고 다음 점검에서 재시도 |

메시지에는 한국어 상태 설명·KST 시각·실제 경과 시간을 포함한다. 웹훅, DB 비밀번호, SQL, 개인 데이터, 비공개 로그 본문은 보내지 않으며 `@everyone` 같은 멘션도 비활성화한다. 네트워크 응답이 유실된 경우 재시도 메시지가 중복될 수 있다.

이 감시는 **백업 실행 기록 감시**다. 복제 스레드가 방금 중단됐는지를 5분마다 SQL로 확인하지 않는다. 복제 이상은 기존 백업의 preflight가 실행될 때 감지되므로 최대 다음 백업까지 늦어질 수 있다. 복제 지연 0초·최신 데이터 일치·복원 성공도 인증하지 않는다.

PC2 전원 OFF·절전·로그아웃이면 백업과 감시가 함께 멈춘다. 인터넷 또는 Discord 장애 중에는 원격 알림이 도착하지 않을 수 있다. 작업 스케줄러 자체 장애나 감시 작업 비활성화도 자기 자신만으로 알릴 수 없다. PC 전체 장애 감지는 별도 장비/외부 감시의 후속 작업이다. 상시 실행을 위해 이번 절차에서 Docker Desktop·예약 계정 방식을 임의 변경하지 않는다.

백업 실패를 시험하려고 MySQL을 중지하거나 원본 JSON·예약 작업을 변조하지 않는다. `TestAlert`는 전송 경로를, 저장소의 모의 시험은 실패/정상화 판정을 검증한다. 실제 현장 장애·복원 성공은 결과를 받은 뒤 기록한다.

## 구현 검증

`infrastructure/tools/tests/mysql84-backup-discord.Tests.ps1`은 임시 가짜 저장소에서 실행된다. HTTP와 Task Scheduler 호출은 대체하며 Docker·라이브 DB·실제 예약·외부 Discord 전송은 사용하지 않는다. DPAPI 암호화, 계정·작업 분리, 실패/지연/장기 실행/파일 누락/상태 손상 판정, 중복 억제·재알림·복구, 실패한 전송 재시도와 설치 코드 해시 보호를 검사한다.

공식 동작 근거: [Discord 웹훅 전송과 wait](https://docs.discord.com/developers/resources/webhook#execute-webhook), [Windows Export-Clixml의 DPAPI 보호](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml?view=powershell-5.1). 기존 절차는 [예약 백업](mysql84-backup-schedule.md), [k3s 이전 영향 점검](mysql84-k3s-impact.md)을 참고한다.
