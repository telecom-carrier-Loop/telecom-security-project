# PC2 Primary 구성의 계획 종료와 다음 시작

2026-10-30 구성 기준이다. Windows PC1 MySQL `flask_mysql`은 Replica, Windows PC2 `mysql-lab`은 Primary다. PC1 Ubuntu는 k3s server, PC2 Ubuntu는 k3s-agent다. 명령은 표시한 장비와 터미널에서만 실행한다.

## 종료 전 확인

다른 담당자에게 종료 시간을 알리고 공격 시험, 사용자 쓰기와 n8n 자동 실행을 마무리한다. CSV·화면과 설정 백업을 개인 보관한다. pfSense 설정 백업에는 비밀이 포함될 수 있으므로 Git에 올리지 않는다.

PC1 Ubuntu에서 실행한다.

```bash
sudo k3s kubectl get nodes -o wide
for name in telecom-api telecom-web telecom-edge telecom-admin-edge telecom-automation-edge; do
  sudo k3s kubectl -n telecom rollout status deployment/$name --timeout=180s || break
done
sudo k3s kubectl -n telecom get deployments
sudo k3s kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
```

두 노드 Ready, 다섯 Deployment 모두 2/2, CoreDNS는 양쪽 노드에 1/1이 기대값이다. 재기동 직후 1/2였다면 위 확인으로 최종 회복을 확인한다. 실패하면 추가 장애 시험을 하지 말고 해당 Pod의 상태와 로그를 기록한다. 계획 종료 자체가 불가능하다는 뜻은 아니다.

PC3 pfSense Stats에서 pc1-web·pc2-web 모두 UP, 전달·검사 포트 30443, MAINT 해제를 확인한다. 프로젝트 CA가 등록된 Windows에서 다음을 실행한다.

```powershell
curl.exe --noproxy "*" --ssl-revoke-best-effort --connect-timeout 3 --max-time 10 -sS -i "https://192.168.3.30/api/health/ready"
```

기대값은 HTTP 200, database ok다. 이 curl 옵션은 인증서 이름·신뢰 검사를 끄지 않으며 폐기 정보 조회가 불가능한 경우의 처리를 완화한다.

## PC2 Windows: 최신 백업 후 예약 작업 일시 중지

기존 도구가 설치된 PC2 Windows PowerShell에서 실행한다. 이 경로는 Git 소스 위치가 아니라 기존 예약 도구·비밀 자료가 보관된 운영 경로다. 폴더를 다시 클론하거나 삭제하지 않는다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $loopRepo = Join-Path $env:USERPROFILE 'telecom-security-project'
    $loopPrimarySchedule = Join-Path $loopRepo '.secrets\backups\mysql84\pc2-primary\scheduler\mysql84-backup-schedule.ps1'
    if (-not (Test-Path -LiteralPath $loopPrimarySchedule -PathType Leaf)) {
        throw '설치된 Primary 백업 도구 경로를 확인하세요.'
    }
    powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopPrimarySchedule" -RepositoryPath "$loopRepo" -SourceRole Primary -Action Test
    if ($LASTEXITCODE -ne 0) { throw '최종 백업 실패. 오류를 확인하세요.' }
}
```

PASS와 task result 0을 확인한 다음, 관리자 PowerShell에서 아래 블록을 별도로 실행한다. 실행 중인 작업이 있으면 강제 중단하지 않고 완료된 뒤 다시 실행한다.

```powershell
& {
    $ErrorActionPreference = 'Stop'
    $loopTasks = @(
        'Loop-MySQL84-PC2-Primary-Hourly-Backup'
        'Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor'
    )
    $loopState = @(Get-ScheduledTask -TaskName $loopTasks)
    if (@($loopState | Where-Object State -eq 'Running').Count -gt 0) {
        throw '백업 또는 감시 실행 중입니다. 완료 후 다시 실행하세요.'
    }
    $loopSavedState = Join-Path $env:USERPROFILE ('Downloads\telecom-tasks-before-shutdown-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
    $loopState | Select-Object TaskName, State | ConvertTo-Json | Set-Content -LiteralPath $loopSavedState -Encoding UTF8
    foreach ($loopTask in $loopTasks) {
        Disable-ScheduledTask -TaskName $loopTask | Out-Null
    }
    Get-ScheduledTask -TaskName $loopTasks | Select-Object TaskName, State
    Write-Host "종료 전 상태 저장: $loopSavedState"
}
```

두 Primary 작업은 Disabled가 된다. 기존 Replica 백업·감시 두 작업도 Disabled를 유지한다. 계획된 야간 중단 중 감시 알림을 피하기 위한 일시 중지이며 다음 시작 때 정상 확인 후 Primary 작업만 재개한다.

## VM과 DB 종료 순서

1. **PC2 Ubuntu VM**: worker를 먼저 정상 종료한다. 아래 한 줄을 실행하고 VMware에서 전원이 꺼졌는지 확인한다.

   ```bash
   sudo shutdown -h now
   ```

2. **PC1 Ubuntu VM**: 같은 명령을 실행한다. 운영체제 종료 과정에서 k3s와 컨테이너도 종료된다. SSH가 끊기는 것은 예상 동작이다. VMware 강제 Power Off 대신 정상 종료를 기다린다.

   ```bash
   sudo shutdown -h now
   ```

3. 관제 담당자와 PC1·PC2의 나머지 앱·자동화 쓰기가 끝났는지 확인한다. **PC1 Windows PowerShell**에서 Replica DB를 먼저 종료한다.

   ```powershell
   docker stop --timeout 120 flask_mysql
   if ($LASTEXITCODE -ne 0) { throw 'PC1 DB 종료 실패. Docker 상태를 확인하세요.' }
   docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}}' flask_mysql
   ```

4. **PC2 Windows PowerShell**에서 Primary DB를 마지막에 종료한다.

   ```powershell
   docker stop --timeout 120 mysql-lab
   if ($LASTEXITCODE -ne 0) { throw 'PC2 DB 종료 실패. Docker 상태를 확인하세요.' }
   docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}}' mysql-lab
   ```

   기대 상태는 exited다. 종료 코드 137 등 강제 종료 징후가 있으면 Docker 로그를 보관하고 다음 시작 때 DB 복구 상태를 먼저 확인한다. Docker stop은 제한 시간을 넘기면 강제 종료할 수 있으므로 완료 출력과 상태를 확인한다.

5. PC1·PC2의 나머지 Docker 관제 서비스는 담당자 운영 절차로 종료한 뒤 Docker Desktop을 종료한다. 다른 VM도 있으면 정상 종료한다.
6. **PC3 pfSense VM**은 네트워크 사용이 끝난 뒤 마지막으로 콘솔 메뉴의 `6) Halt system`을 선택하고 확인한다. 화면에서 정지를 확인한 다음 Windows를 종료한다.
7. PC1·PC2·PC3 Windows를 시작 메뉴의 종료로 끈다. VMware VM과 Docker가 모두 정지했는지 먼저 확인한다.

이 순서에서는 DB 역할 변경, Deployment 복제 수 변경, 복제 초기화, 볼륨 삭제가 필요하지 않다. `docker compose down -v`, `RESET REPLICA`, PC2의 이전 복제 채널 시작은 실행하지 않는다. 학원 공용 스위치는 종료 대상으로 삼지 않는다.

## 다음 시작 순서

1. Windows의 기존 IP와 네트워크를 확인하고 Docker Desktop을 시작한다. PC3 pfSense VM을 켜서 관리 화면과 HAProxy를 복구한다. 기존 주소를 임의로 재설정하지 않는다.
2. **PC2 Windows**에서 `docker start mysql-lab`을 실행하고 MySQL 준비 완료를 기다린다. root로 확인할 때는 비밀번호를 명령문에 넣지 않는다.

   ```powershell
   docker exec -e MYSQL_HISTFILE=/dev/null -it mysql-lab mysql --user=root --password
   ```

   MySQL 안에서 실행한다.

   ```sql
   SELECT @@server_id, @@read_only, @@super_read_only;
   SHOW REPLICA STATUS\G
   ```

   기대값은 2, 0, 0이다. 이전 PC1→PC2 채널이 남아 있다면 IO·SQL No가 의도한 상태다. 이 채널을 시작하지 않는다.
3. **PC1 Windows**에서 `docker start flask_mysql` 실행 후 root로 접속한다.

   ```powershell
   docker exec -e MYSQL_HISTFILE=/dev/null -it flask_mysql mysql --user=root --password
   ```

   ```sql
   SELECT @@server_id, @@read_only, @@super_read_only;
   SHOW REPLICA STATUS FOR CHANNEL 'pc2_to_pc1'\G
   ```

   기대값은 1, 1, 1이다. 복제는 IO·SQL Yes, 오류 없음, TLS 검증 Yes를 확인한다. 역할이 다르거나 복제가 실패하면 쓰기 차단을 해제하거나 초기화하지 말고 오류부터 확인한다.
4. **PC1 Ubuntu VM**을 먼저 켜고 필요하면 `sudo systemctl start k3s`, 이어 **PC2 Ubuntu VM**에서 필요하면 `sudo systemctl start k3s-agent`를 실행한다. 서비스가 자동 시작되었다면 다시 설치할 필요가 없다.
5. 이 문서의 종료 전 k3s·CoreDNS·HAProxy·HTTPS 검사를 반복한다. 두 API의 실제 DB 대상이 PC2 `192.168.3.19`인지 확인한다.
6. **PC2 Windows 관리자 PowerShell**에서 Primary 백업 작업만 활성화한다.

   ```powershell
   Enable-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Primary-Hourly-Backup'
   ```

   위의 Primary 예약 백업 `-Action Test` 블록을 다시 실행해 PASS를 확인한다. 성공한 뒤 감시를 재개한다.

   ```powershell
   Enable-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor'
   Start-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor'
   Get-ScheduledTask -TaskName 'Loop-MySQL84-PC2-Primary-*' | Select-Object TaskName, State
   ```

7. 관제 자동 실행을 재개하고 로그인·읽기·쓰기·복제 검증과 전용 내부 API 연동 시험을 담당자와 진행한다. 검증 중 다른 공격 시험과 계정 잠금 시험이 겹치지 않도록 시간을 분리한다.

## 명령 기준

- [Docker stop 공식 문서](https://docs.docker.com/reference/cli/docker/container/stop/): 종료 유예 시간과 강제 종료 동작.
- [K3s 구성 공식 문서](https://docs.k3s.io/installation/configuration): systemd 서비스 구성과 기존 설정 유지.
