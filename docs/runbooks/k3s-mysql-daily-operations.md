# k3s·MySQL 작업 종료, 다음 날 시작, 장애 전환 준비

기준: 2026-10-22 KST. 현장 명령 안내이며 이 문서 작성 PC에서 서버 종료·재부팅·DB 승격을 수행한 기록이 아니다. PC1·PC2의 기존 VM·Docker 컨테이너·볼륨·k3s 설치를 유지한다.

| 실행 장소 | 현재 역할/주소 |
|---|---|
| PC1 Windows | Docker Desktop, Primary `flask_mysql`, DB `192.168.3.18:3306` |
| PC2 Windows | Docker Desktop, Replica `mysql-lab`, 기존 DB 주소 `192.168.3.19:3306`는 재확인 필요. 예약 백업·Discord 감시 |
| PC1 Ubuntu VM | `pc1-k3s`, `192.168.7.185`, k3s Server+Worker |
| PC2 Ubuntu VM | `pc2-k3s`, `192.168.7.100`, k3s Agent/Worker |

아래 일상 운영 절차는 **PC1 Primary / PC2 Replica 역할을 바꾸지 않은 경우**에만 적용한다. 승격 후에는 구 Primary를 일반 시작 순서로 자동 복귀시키면 안 된다. 비밀번호·웹훅·kubeconfig·SQL 덤프를 채팅이나 Git에 올리지 않는다.

## 먼저 구분할 사항

정상 종료 후 다음 날 다시 켜는 것은 DB 장애 전환이 아니다. 매일 복제 초기화, Restore/Activate, DB 승격, 이미지 재반입이나 k3s 재설치를 하지 않는다. 수동 `docker stop` 뒤에는 `unless-stopped` 컨테이너가 Docker 재시작만으로 다시 켜지지 않을 수 있어 `docker start`를 명시적으로 사용한다.

2026-10-22 사용자 확인상 MySQL `root@localhost` 오류 1045는 아직 미해결이다. 저장된 `loop_backup`으로 백업·복원에 성공한 것과 관리자 인증은 별개다. 일상 종료·시작에는 저장된 계정을 사용하지만 DB 승격 전에는 관리자 접속을 해결해야 한다.

## A. 작업을 마칠 때

### A1. 업무 입력과 자동화 중지 — 각 담당 프로그램

사용자 입력을 마치고 DB에 쓰는 n8n 워크플로우, 이전 개발 Flask/React, 다른 쓰기 프로그램을 일시 중지한다. n8n 전체 설정이나 데이터를 삭제하지 않는다. 중지한 자동화 목록을 기록하고 다음 날 정상 점검 후 재개한다.

### A2. 웹과 API 중지 — PC1 Ubuntu

아래 블록은 `telecom`의 두 Deployment를 각각 0개로 줄인다. 이 값은 저장되므로 다음 날 각 2개로 되돌리는 단계가 필요하다.

```bash
(
set -eu
sudo k3s kubectl -n telecom scale deployment/telecom-web --replicas=0
sudo k3s kubectl -n telecom rollout status deployment/telecom-web --timeout=180s
sudo k3s kubectl -n telecom scale deployment/telecom-api --replicas=0
sudo k3s kubectl -n telecom rollout status deployment/telecom-api --timeout=180s
sudo k3s kubectl -n telecom get deployment
sudo k3s kubectl -n telecom get pods -o wide
)
```

오류가 나거나 앱 Pod가 아직 종료 중이면 완료를 확인한 뒤 진행한다. `k3s-smoke`의 테스트 Pod가 남아 있는 것과 업무 앱 중지는 구분한다.

### A3. 예약 일시 중지와 최종 백업 — PC2 Windows PowerShell

한 블록 전체를 붙여 넣는다. 원래 백업 Windows 사용자로 실행한다. Disable은 예약을 삭제하거나 실행 중인 백업을 강제 종료하지 않는다. 실행 중이면 블록이 중단되므로 완료를 기다리고 다시 실행한다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $loopRepo = 'C:/Users/user/telecom-security-project'
    $loopBackupRoot = Join-Path $loopRepo '.secrets/backups/mysql84/pc2'
    $loopSchedule = Join-Path $loopBackupRoot 'scheduler/mysql84-backup-schedule.ps1'
    $loopTaskNames = @('Loop-MySQL84-PC2-Backup-Discord-Monitor','Loop-MySQL84-PC2-Hourly-Backup')
    foreach ($loopTaskName in $loopTaskNames) {
        $null = Get-ScheduledTask -TaskName $loopTaskName -ErrorAction Stop
        $null = Disable-ScheduledTask -TaskName $loopTaskName
    }
    foreach ($loopTaskName in $loopTaskNames) {
        if ((Get-ScheduledTask -TaskName $loopTaskName).State -eq 'Running') {
            throw '실행 중인 작업이 있습니다. 완료를 기다린 뒤 이 블록부터 다시 실행하세요.'
        }
    }
    # Run은 설치된 예약 worker의 백업 처리를 직접 실행한다.
    # 예약은 Disabled로 유지하며 last-run/last-success도 갱신한다.
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Run
    if ($LASTEXITCODE -ne 0) { throw '최종 백업 실패. 서버를 끄기 전에 원인을 확인하세요.' }
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Status
    if ($LASTEXITCODE -ne 0) { throw '최종 백업 상태를 확인하세요.' }
    Get-ScheduledTask -TaskName $loopTaskNames | Select-Object TaskName,State
}
```

`PASS: scheduled BackupSaved completed`, 새 last-run/last-success의 success, 두 예약 Disabled를 확인한다. 여기서의 Run은 실제 백업 생성이며 Task Scheduler 트리거 실행 시험은 아니다. Status의 Last task result는 이전 예약 실행 값이다. 이번 성공 여부는 새 실행 기록도 함께 확인한다. 이 백업의 Replica 보호 검사는 통과했지만 PC1의 마지막 GTID까지 일치한다는 검사는 별개다. 역할은 그대로 유지한다.

백업에 실패하면 그대로 전원을 끄지 말고 원인을 확인한다. 작업을 계속 운영하기로 했다면 다음 날 재개 절차에 따라 두 예약도 다시 활성화한다.

### A4. Ubuntu VM 종료 — PC2 Ubuntu 먼저, PC1 Ubuntu 나중

각 VM 안에서 실행한다.

```bash
sudo poweroff
```

SSH 연결이 끊기는 것은 정상이다. VMware에서 해당 VM이 **Powered Off**가 된 것을 확인한다. VMware의 강제 Power Off 또는 Suspend 대신 게스트 OS 정상 종료를 사용한다. 일상 종료에 uninstall/killall 스크립트를 사용하지 않는다. k3s 서비스는 OS 종료 과정에서 정리되며 설치·클러스터 상태는 보관된다.

### A5. MySQL 컨테이너 종료 — PC2 Windows 먼저

PC2 Windows PowerShell:

```powershell
docker stop --time 120 mysql-lab
docker inspect --format 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' mysql-lab
```

PC1 Windows PowerShell:

```powershell
docker stop --time 120 flask_mysql
docker inspect --format 'name={{.Name}} status={{.State.Status}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' flask_mysql
```

각각 exited/exit=0/oom=false인지 확인한다. 120초 내 종료되지 않아 강제 종료되거나 비정상 종료 코드가 보이면 정상 종료로 기록하지 말고 로그를 확인한다. 컨테이너·볼륨 삭제나 `docker compose down -v`를 실행하지 않는다. 보관 중인 과거 DB·복원 시험 컨테이너를 일괄 시작/종료 대상으로 선택하지 않는다.

### A6. Windows 종료

다른 팀의 Docker 서비스·VM도 각 담당 절차로 정상 종료됐는지 확인한 뒤 Docker Desktop을 Quit한다. 마지막으로 Windows 시작 메뉴에서 시스템 종료한다. 순서는 업무 앱 → 최종 백업 → Ubuntu VM → MySQL 컨테이너 → Docker Desktop → Windows다. pfSense가 구성된 이후에는 이 경로를 쓰는 장비가 종료된 다음 pfSense도 정상 종료한다.

## B. 다음 날 시작할 때

### B1. Windows·네트워크·Docker Desktop

PC1·PC2 Windows를 켜고 원래 사용자로 로그인한다. 두 PC에서 Docker Desktop을 실행하고 준비가 끝날 때까지 기다린다. pfSense가 네트워크 경로가 된 이후에는 pfSense와 필요한 네트워크를 먼저 정상화한다.

각 Windows PowerShell:

```powershell
docker info --format '{{.ServerVersion}}'
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -like '192.168.3.*' } |
    Select-Object InterfaceAlias,IPAddress,PrefixLength
```

PC1 DB 주소가 192.168.3.18인지, PC2의 실제 주소가 무엇인지 확인한다. 주소가 달라졌다면 기존 설정으로 업무를 열지 말고 네트워크부터 확인한다. VM IP와 Windows DB IP는 다른 주소다.

### B2. 기존 MySQL 컨테이너 시작

PC1 Windows:

```powershell
docker start flask_mysql
docker inspect --format 'name={{.Name}} status={{.State.Status}}' flask_mysql
```

PC2 Windows:

```powershell
docker start mysql-lab
docker inspect --format 'name={{.Name}} status={{.State.Status}}' mysql-lab
```

기존 컨테이너만 시작한다. 복원 시험 컨테이너·과거 보존 컨테이너를 시작하지 않는다. running은 mysqld 준비 완료나 복제 정상의 증명이 아니므로 이후 새 백업과 앱 준비 검사를 확인한다. 현재 PC2 설정의 `--skip-replica-start=OFF`에 따라 저장된 채널의 자동 재개를 기대하지만 실제 정상 여부는 검사해야 한다.

### B3. Ubuntu VM과 k3s 시작

VMware에서 기존 PC1·PC2 Ubuntu VM을 켠다. 먼저 VM 콘솔에서 각 hostname과 IPv4를 확인한다.

양쪽 Ubuntu:

```bash
hostname
ip -br -4 addr
ip -4 route
swapon --show
timedatectl
```

PC1은 pc1-k3s/192.168.7.185, PC2는 pc2-k3s/192.168.7.100이 기준이다. DHCP 주소가 바뀌었다면 임의로 YAML을 재적용하지 말고 주소 고정부터 확인한다. Swap 출력이 있으면 메모리 상태를 확인하고 `sudo swapoff -a`로 비활성화한다. 재발 방지는 `sudo vi /etc/fstab`에서 **실제 swap 항목만** 확인해 처리한다. 다른 마운트 항목은 변경하지 않는다.

PC1 Ubuntu:

```bash
sudo systemctl enable --now k3s
sudo systemctl is-active k3s
```

PC2 Ubuntu:

```bash
sudo systemctl enable --now k3s-agent
sudo systemctl is-active k3s-agent
```

부팅 시 이미 자동 시작됐다면 enable --now는 서비스를 다시 설치하지 않는다. PC1에서는 예전에 잘못 설치했던 별도 k3s-agent를 시작하지 않는다. k3s Server에 Worker 기능이 이미 포함된다.

PC1 Ubuntu에서 노드 확인:

```bash
sudo k3s kubectl wait --for=condition=Ready node/pc1-k3s node/pc2-k3s --timeout=180s
sudo k3s kubectl get nodes -o wide
```

두 노드 모두 Ready인지 확인한다. 일상 부팅에 설치 curl, join 토큰 재등록, 원래 base YAML 재적용은 필요 없다.

### B4. 새 백업으로 점검 후 예약 재개 — PC2 Windows

밤에 두 예약을 Disabled로 유지했다는 전제다. 먼저 저장된 계정으로 새 백업을 만들고, 성공한 경우에만 기존 백업·감시 예약을 다시 활성화한다. 이 순서로 야간 계획 중지 시간을 오래된 백업 알림으로 보내는 것을 줄인다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $loopRepo = 'C:/Users/user/telecom-security-project'
    $loopBackupRoot = Join-Path $loopRepo '.secrets/backups/mysql84/pc2'
    $loopSchedule = Join-Path $loopBackupRoot 'scheduler/mysql84-backup-schedule.ps1'
    $loopAlert = Join-Path $loopBackupRoot 'discord-monitor/mysql84-backup-discord.ps1'
    $loopBackupTask = 'Loop-MySQL84-PC2-Hourly-Backup'
    $loopMonitorTask = 'Loop-MySQL84-PC2-Backup-Discord-Monitor'
    foreach ($loopTaskName in @($loopBackupTask,$loopMonitorTask)) {
        if ((Get-ScheduledTask -TaskName $loopTaskName -ErrorAction Stop).State -ne 'Disabled') {
            throw '밤에 중지한 예약이 Disabled 상태가 아닙니다. Status와 실행 중 여부를 확인하세요.'
        }
    }
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Run
    if ($LASTEXITCODE -ne 0) { throw '새 백업 또는 복제 보호 검사 실패. 먼저 원인을 확인하세요.' }
    $null = Enable-ScheduledTask -TaskName $loopBackupTask
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action Check
    if ($LASTEXITCODE -ne 0) { throw '감시 점검에서 이상을 감지했습니다. Discord와 Status를 확인하세요.' }
    $null = Enable-ScheduledTask -TaskName $loopMonitorTask
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopSchedule" -RepositoryPath "$loopRepo" -Action Status
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopAlert" -RepositoryPath "$loopRepo" -Action Status
    Get-ScheduledTask -TaskName $loopBackupTask,$loopMonitorTask | Select-Object TaskName,State
}
```

새 백업 PASS와 두 예약 Ready/정상 Running을 확인한다. 중간 오류로 중단되면 일부 예약만 활성화됐을 수 있으므로 상태를 확인하고 복구한다. Check 실패를 무시한 채 매번 전체 블록을 다시 실행하지 않는다. 계획 종료와 달리 정전 후 시작한 경우에는 오래된 백업 알림이 실제 공백을 뜻할 수 있으므로 숨기지 않는다.

### B5. API와 웹 재개 — PC1 Ubuntu

```bash
(
set -eu
sudo k3s kubectl -n telecom scale deployment/telecom-api --replicas=2
sudo k3s kubectl -n telecom rollout status deployment/telecom-api --timeout=300s
sudo k3s kubectl -n telecom scale deployment/telecom-web --replicas=2
sudo k3s kubectl -n telecom rollout status deployment/telecom-web --timeout=300s
sudo k3s kubectl -n telecom get pods -o wide
)
```

API 2개·웹 2개가 Ready/Running인지 확인한다. required anti-affinity 때문에 한 노드가 준비되지 않으면 두 번째 Pod가 Pending일 수 있다. `imagePullPolicy: Never`이므로 재생성된 Pod가 이미지를 못 찾으면 해당 노드의 기존 containerd 이미지부터 확인한다. 정상 재부팅이라면 디스크에 저장된 이미지는 재반입할 필요가 없다. smoke/DB 테스트 Pod의 완료 상태를 새로 실행할 필요는 없다.

### B6. 임시 웹 접속 다시 연결

PC1 Ubuntu의 별도 창을 열어 계속 켜 둔다.

```bash
sudo k3s kubectl -n telecom port-forward service/telecom-web 18080:80 --address=127.0.0.1
```

웹 브라우저를 사용할 Windows의 별도 PowerShell 창을 열어 계속 켜 둔다.

```powershell
ssh -o ExitOnForwardFailure=yes -N -L 127.0.0.1:18080:127.0.0.1:18080 loop@192.168.7.185
```

브라우저에서 `http://localhost:18080`에 접속해 로그인·회원 목록 등 조회를 확인한다. 승인된 테스트 데이터로 쓰기도 검증한 뒤 중지했던 n8n 워크플로우 등 자동화를 재개한다. 포트 전달과 SSH 터널은 재부팅 후 다시 실행해야 한다. pfSense 정식 진입점 구성 이후에는 이 임시 접속 대신 확정된 주소로 확인한다.

### B7. 첫 정기 실행 확인

5~10분 뒤 Discord 감시 Status의 CheckedUtc가 새로워지는지, 다음 시간별 백업 예약 시각 이후에는 last-run/last-success와 Task result가 새 실행 성공을 표시하는지 확인한다. 매번 TestAlert·Install·Repair를 다시 실행하지 않는다. 정상 상태에서는 Discord가 조용하다. 고의로 MySQL을 끄는 방식으로 알림을 시험하지 않는다.

## C. DB 장애 전환을 실제로 실행하기 전에

### C1. 관리자 인증 — 지금 가능한 첫 점검

PC1 Windows:

```powershell
docker exec -it flask_mysql mysql --user=root --password
```

PC2 Windows:

```powershell
docker exec -it mysql-lab mysql --user=root --password
```

각각 해당 PC의 현재 MySQL 관리자 비밀번호를 입력한다. Ubuntu/Windows 로그인 비밀번호와 같다고 가정하지 않는다. 접속된 `mysql>`에서 **조회만** 수행한다.

```sql
SELECT CURRENT_USER(), VERSION(), @@server_id, @@read_only, @@super_read_only;
```

PC1은 server_id 1 / 읽기 전용 두 값 0, PC2는 server_id 2 / 두 값 1이 현재 기준이다. PC2에서는 다음 조회도 수행한다.

```sql
SHOW REPLICA STATUS\G
```

오류 1045가 계속 나면 승격 전에 인증 문제부터 해결한다. 비밀번호를 채팅으로 보내거나 root 비밀번호 초기화·인증 비활성화를 일상 복구 단계로 실행하지 않는다. 기존 앱은 PC1의 root@%로 접속해 조회에 성공했으므로 root@localhost와 구분하여 현재 계정·권한을 확인할 수 있다. 이 관리자 접속 점검 실패가 기존 저장된 loop_backup 백업까지 실패했다는 뜻은 아니다.

### C2. PC1 DB만 장애/계획 전환, k3s Server는 정상인 경우

현재 통합 승격 도구와 승격 후 Primary 백업 모드는 구현돼 있지 않다. 다음은 순서와 완료 조건이다. C1 인증, 양쪽 앱 계정·권한, 새 Primary의 백업·격리 복구·예약이 준비되기 전에는 라이브 승격을 시작하지 않는다.

| 순서 | 실행할 작업 | 완료 조건 |
|---|---|---|
| 1 | 업무 앱과 다른 DB 쓰기를 중지하고 기존 백업·복원 기록 확인 | 관리자 접속·복원 가능한 백업 자료 확보 |
| 2 | PC1 쓰기 차단(fencing). 계획 전환이면 PC1을 읽기 전용으로 고정한 뒤 최종 GTID 기록 | 구 Primary로 새 쓰기가 들어갈 수 없음 |
| 3 | PC2가 기록한 GTID를 모두 적용했는지 `WAIT_FOR_EXECUTED_GTID_SET`로 확인 | 반환 0, 복제 오류 없음. 지연 0초만으로 대체하지 않음 |
| 4 | 동기화된 Replica의 최종 백업 후 기존 예약 백업·감시의 유지보수 처리. PC2 복제 중지와 쓰기 역할 전환 | 최신 백업 성공, PC2만 쓰기 가능. 재부팅 후 역할도 유지 |
| 5 | Kubernetes의 DB 대상과 필요한 앱 Secret 변경, API 재생성 | 두 API Pod 모두 PC2 DB의 올바른 UUID/server_id/역할로 접속 |
| 6 | 로그인과 승인된 쓰기 검증 후 새 역할의 백업 재개 | 새 Primary 백업·복원·예약 검증. 기존 Replica 전용 보호 검사 삭제로 우회하지 않음 |
| 7 | PC1 복귀 시 새 Primary 기준 재동기화·역방향 복제·원복 검증 | PC1을 바로 읽기/쓰기 Primary로 시작하지 않음 |

계획 전환과 달리 PC1에 접근할 수 없는 긴급 장애에서는 최종 GTID를 읽을 수 없을 수 있다. 적용된 데이터·수신된 relay log·미전송 트랜잭션 손실 가능성을 평가하고 구 Primary가 돌아와도 쓰지 못하도록 통제해야 한다. 단순히 PC2의 read_only를 끄는 것으로 완료되지 않는다.

PC2 앱 계정과 비밀번호가 PC1과 같다는 보장은 없다. DB_HOST 변경만으로 인증 문제가 해결되지는 않는다. 역방향 복제는 기존 PC1 인증서 SAN·접속 권한을 PC2에 그대로 적용할 수 있다고 가정하지 않는다. 기존 `mysql84-replica.ps1`의 Stage/Restore/Activate와 버전 전환용 cutover 도구를 승격·원복 도구로 재실행하지 않는다.

### C3. PC1 전체 장애와 k3s 구조

현재 PC1 전체가 꺼지면 Kubernetes API server도 사라져 PC2 Agent에서 ConfigMap 변경·새 rollout을 수행할 수 없다. 일부 기존 컨테이너가 계속 떠 있을 수 있어도 관리 기능과 정상 서비스 지속을 보장하지 않는다.

사용자 제약은 PC1·PC2 물리 장비 안에만 VM 추가 가능이다. embedded etcd는 3개 이상 Server와 과반수가 필요하다. 3개 Server를 두 물리 PC에 배치할 때의 결과는 다음과 같다.

| Server 배치 | PC1 전체 장애 | PC2 전체 장애 |
|---|---|---|
| PC1에 1개 / PC2에 2개 | 2개가 남아 과반수 유지 | 1개만 남아 과반수 상실 |
| PC1에 2개 / PC2에 1개 | 1개만 남아 과반수 상실 | 2개가 남아 과반수 유지 |

따라서 두 물리 PC만으로 어느 한쪽이 꺼져도 살아남는 embedded etcd 고가용성을 보장할 수 없다. PC1 장애 우선 대응이 목표라면 PC2에 Server 2개를 배치하는 비대칭 설계를 검토할 수 있지만 메모리/CPU, 별도 VM 주소, 고정 API 진입점, agent 재접속, CNI와 이미지 보유, 웹 진입점·DB 계정·백업을 함께 설계해야 한다. 단순히 PC2 Agent를 Server로 바꾸거나 새 VM에 기본 설치만 하는 절차가 아니다. 이 문서에서 해당 마이그레이션을 실행하지 않는다.

장비를 추가하기 전에는 단일 Server의 datastore·token 백업과 수동 복구 절차를 준비하고 복구 시간을 측정하는 방법을 사용할 수 있다. 이것은 무중단 HA가 아니다. pfSense가 물리 PC3에서 동작하더라도 사용자 답변상 별도 Ubuntu Server를 그 장비에 추가할 수 있는 것으로 가정하지 않는다.

## D. k3s 제어부 백업 자료

k3s datastore 종류부터 확인한다. SQLite이면 `/var/lib/rancher/k3s/server/db/`, embedded etcd이면 etcd snapshot 방식이 필요하다. **어느 경우든 `/var/lib/rancher/k3s/server/token`을 함께 보관**해야 한다. 설치 설정·서비스 환경, 현장 앱 YAML·이미지 및 외부 MySQL 백업도 별도 필요하다. MySQL 덤프는 Kubernetes 상태를 포함하지 않는다.

SQLite라고 확인한 뒤, 업무 앱을 중지한 유지보수 시간에 k3s Server를 멈추고 db 디렉터리·token·설정의 일관된 사본을 만든다. 살아 있는 서버의 파일을 다른 노드에 그대로 덮어쓰는 복구를 실행하지 않는다. PC1 디스크에만 둔 사본은 PC1 디스크 장애에 대한 복구 자료가 아니므로 보호된 다른 장비 사본도 필요하다. 실제 datastore/설정 확인 전에는 SQLite 복구 명령이나 etcd cluster-reset을 임의 적용하지 않는다.

## 참고

- [K3s embedded etcd 과반수와 Server 구성](https://docs.k3s.io/datastore/ha-embedded)
- [K3s datastore와 token 백업](https://docs.k3s.io/datastore/backup-restore)
- [Docker unless-stopped 동작](https://docs.docker.com/engine/containers/start-containers-automatically/)
- [MySQL GTID 적용 대기 함수](https://dev.mysql.com/doc/refman/8.4/en/gtid-functions.html)
- [MySQL 장애 전환](https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-switch.html)
- [k3s 이전에 따른 복제·백업 영향](mysql84-k3s-impact.md)
- [복원·Discord 감시 설정과 확인](mysql84-restore-discord.md)
