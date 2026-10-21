# PC2 MySQL 1시간 주기 백업

## 적용 상태

PC1 flask_mysql(192.168.3.18) → PC2 mysql-lab(192.168.3.19) TLS·GTID 복제와 PC2 읽기 전용을 유지한다. 현장에서 암호화 자격 증명 저장, BackupSaved의 비대화형 백업, 새 백업의 22개 테이블 격리 복구 PASS를 확인했다. 이 문서는 그다음 단계인 **Windows 작업 스케줄러의 1시간 주기 등록**이다. PC2에서 Install·Test를 통과하기 전에는 실제 예약 완료로 보고하지 않는다.

## 설치와 실행 검증

수정된 mysql84-backup.ps1 및 mysql84-backup-schedule.ps1을 받은 뒤 **PC2의 기존 Windows 사용자**로 실행한다. 예시는 TEMP에 각각 loop-mysql84-backup.ps1, loop-mysql84-backup-schedule.ps1으로 받은 경우다. 기존 자격 증명을 다시 저장하거나 root 비밀번호를 입력하지 않는다.

```powershell
& {
    $loopArguments = @(
        '-NoLogo', '-NoProfile', '-NonInteractive',
        '-ExecutionPolicy', 'RemoteSigned',
        '-File', "$env:TEMP/loop-mysql84-backup-schedule.ps1",
        '-RepositoryPath', 'C:/Users/user/telecom-security-project',
        '-BackupToolPath', "$env:TEMP/loop-mysql84-backup.ps1",
        '-Action', 'Install'
    )
    & powershell @loopArguments
    if ($LASTEXITCODE -ne 0) { throw '예약 등록 실패. 여기서 중단하고 오류를 확인하세요.' }
}
```

Install은 최신 백업의 restore-verified와 현재 Windows 사용자가 복호화할 수 있는 loop_backup 자격 증명을 확인한다. 이어 현재 사용자/SYSTEM 전용 폴더 `.secrets/backups/mysql84/pc2/scheduler`에 두 도구의 고정 복사본·SHA256·Docker CLI 경로·사용자 SID를 기록한다. TEMP 정리나 Git 브랜치 변경으로 예약 코드가 사라지지 않는다. 기존 이름의 다른 작업은 덮어쓰지 않으며 같은 설치의 재실행도 도구를 교체하지 않는다.

등록되는 작업은 `Loop-MySQL84-PC2-Hourly-Backup`이다.

- 설치 약 1시간 뒤부터 1시간 간격으로 반복한다. 반복 종료 기간은 지정하지 않는다. 정각 실행을 의미하지 않는다.
- 현재 Windows 사용자의 InteractiveToken·일반 권한으로 실행한다. 비밀번호를 작업 인수에 넣거나 SYSTEM 계정으로 실행하지 않는다.
- 숨김 PowerShell에서 고정 도구의 Run 액션만 실행하며 내부에서는 BackupSaved만 호출한다. 라이브 복원이나 격리 복구 시험은 매시간 실행하지 않는다.
- 중복 인스턴스는 무시하고 실행 시간은 최대 10분이다. 놓친 실행은 사용 가능할 때 시작하도록 설정한다.
- 먼저 비활성 상태로 등록하고 실제 XML의 계정·실행 경로·주기·기간·권한·실행 제한을 검사한 뒤 활성화한다.

Install PASS는 등록 확인이다. 다음 명령으로 **실제 작업 스케줄러를 통해** 즉시 한 번 실행한다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$env:TEMP/loop-mysql84-backup-schedule.ps1" -RepositoryPath 'C:/Users/user/telecom-security-project' -Action Test
```

최대 90초 동안 새로운 실행 ID, 새 backup-ready 백업, 작업 완료와 종료 결과 0을 확인한다. 이전 성공 기록만으로 이번 실행이 성공했다고 판정하지 않는다.

정상 메시지:

```text
PASS: real Task Scheduler execution created a new complete backup; task result=0.
Task: Loop-MySQL84-PC2-Hourly-Backup
Interval: 1 hour; ...
Last task result: 0x00000000
last-run.json: success; ...
last-success.json: success; ...
```

등록 직후 아직 실행 전인 0x00041303은 이번 실행의 성공 코드가 아니다. Test가 시간 초과이면 작업이 계속 실행 중일 수 있으므로 다시 시작하지 말고 Status를 확인한다. 이미 Running인 작업에는 Test가 추가 실행을 요청하지 않는다.

## 상태·로그와 운영 조건

TEMP 파일이 없어져도 설치된 고정 경로에서 조회할 수 있다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File 'C:/Users/user/telecom-security-project/.secrets/backups/mysql84/pc2/scheduler/mysql84-backup-schedule.ps1' -RepositoryPath 'C:/Users/user/telecom-security-project' -Action Status
```

Status는 다음 실행 시각, 스케줄러 종료 코드, 최근 실행·마지막 성공의 시각과 백업 경로, 비공개 로그 경로를 표시한다. 실패가 나도 last-success.json은 이전 성공을 유지한다. 상태 JSON은 원자적으로 교체하므로 실행 중 조회에서 부분 JSON을 읽지 않게 한다. 코드 해시나 작업 정의가 달라지면 실행·재등록을 중단한다.

PC가 켜져 있고 절전 상태가 아니며 **기존 Windows 사용자가 로그인한 상태**여야 한다. 화면 잠금과 로그아웃은 다르다. 로그아웃·전원 종료 동안 이 구성으로 백업을 보장할 수 없으며 Docker Desktop과 MySQL도 실행 중이어야 한다. 로그아웃 상태의 서버 운영은 별도 서비스 구성이 필요하다.

스키마 마이그레이션은 백업과 겹치지 않게 조율한다. 작업을 비활성화한 뒤 이미 실행 중인 백업이 끝났는지 확인하고 진행한다. 완료 후 다시 활성화한다.

```powershell
Disable-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Hourly-Backup'
Get-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Hourly-Backup' | Select-Object TaskName, State
```

마이그레이션 완료 후:

```powershell
Enable-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Hourly-Backup'
```

스케줄러 강제 종료·10분 제한·PC 전원 중단에서는 마지막 실행이 running으로 남을 수 있다. 종료 코드와 로그를 확인하고 백업 성공으로 취급하지 않는다. 이 경우 보호된 임시 인증 파일과 partial 파일도 점검 대상이다. 원본·라이브 DB나 볼륨은 삭제하지 않는다.

백업은 기존 `.secrets/backups/mysql84/pc2/<실행 폴더>`에 계속 생성한다. **자동 삭제·보관 기간 정리·외부 장치 복사는 포함하지 않는다.** 같은 디스크의 예약 백업만으로 디스크 장애를 대비할 수 없으므로 검증한 사본의 별도 장치 보관을 이어간다. 비밀번호·SQL·로그 전체를 공개하지 않는다.

## 검증 범위

Windows PowerShell 5.1에서 실제 ScheduledTasks CIM 객체의 PT1H·기간 없음·Interactive/Limited·10분 제한을 확인했다. 대역 시험에서는 설치 정의와 변조 차단, 중복 설치·실행 보호, 실패 시 마지막 성공 보존, 이전 결과 오인 방지, 종료 코드 0이어도 새 백업이 없으면 실패하는 동작을 검사했다. 공백·앰퍼샌드가 포함된 경로에서 실제 숨김 PowerShell 프로세스로 등록 명령행·작업 코드·상태 파일 교체를 검증했다. 실제 작업 등록과 Docker/MySQL은 대역이며 현장 PC2의 Install·Test 결과가 최종 확인이다.

근거: [반복 기간 생략 시 무기한 반복](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-duration-repetitiontype-element), [InteractiveToken은 로그인한 사용자 세션에서 실행](https://learn.microsoft.com/en-us/windows/win32/taskschd/taskschedulerschema-logontype-principaltype-element), [예약 작업 실행 설정](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/new-scheduledtasksettingsset).
