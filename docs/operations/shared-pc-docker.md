# 공용 PC 두 대의 Docker MySQL 복제 시작

## 이번 단계의 목표

| 장비 | 사용자가 확인한 유선 IP | 역할 |
|---|---|---|
| PC1 | 192.168.3.18 | MySQL Primary, 호스트 TCP 3306 공개 |
| PC2 | 192.168.3.19 | MySQL Replica, 호스트 DB 포트 미공개 |
| 노트북 | 별도 | 개발·GitHub·작업 안내 |

두 공용 PC에서 Docker Desktop 및 hello-world 실행이 확인되었습니다. Windows 11의 Docker Desktop/Linux 컨테이너와 PowerShell을 사용하며, 별도의 Ubuntu VM을 만들지 않습니다. 이 단계에는 k3s·웹 VIP·pfSense·관제·앱 배포를 포함하지 않습니다. 학원망의 현재 IP를 사용하며 원래 VLAN10~50 설계가 적용된 것으로 표시하지 않습니다.

DB는 이미 검증한 MySQL 8.4.11 digest로 고정합니다. 두 PC의 서버 ID와 root 비밀번호는 서로 다릅니다. GTID 자동 위치 지정, TLS 서버 이름 검증, PC2 전용 클라이언트 인증서와 복제 비밀번호를 사용합니다. 앱 스키마는 건드리지 않고 합성 검증용 `telecom_infra_check`만 추가합니다. root는 컨테이너 로컬 소켓으로만 접근하며 원격 root 계정을 만들지 않습니다.

공식 이미지의 MYSQL_ROOT_HOST 기본값은 `%`이므로 양쪽 구성에 `localhost`를 명시합니다. up은 기존 볼륨에 원격 root 계정이 남아 있으면 중단하며, 환경변수만 바꿔 기존 계정이 삭제된다고 가정하지 않습니다.

## 0. 공통 준비

두 PC에서 저장소 루트로 이동합니다. 수정 파일이 있으면 먼저 보존하며, 깨끗한 작업 폴더에서 제공받은 최신 브랜치를 받습니다.

```powershell
Set-Location C:\Users\user\telecom-security-project
git status --short
git fetch origin
git switch infra/pc-compose
git pull --ff-only origin infra/pc-compose
docker version
```

아래 명령은 해당 PC의 PowerShell에서 직접 실행합니다. `-ExecutionPolicy RemoteSigned`는 검토한 저장소 스크립트를 실행하는 새 PowerShell 프로세스에만 적용하며 시스템 정책을 영구 변경하지 않습니다. 학원에서 정책으로 실행을 제한한 경우 관리자와 확인하고 정책을 우회하지 않습니다. Python·별도 OpenSSL 설치는 필요하지 않습니다. 인증서 생성은 고정된 공식 MySQL 이미지의 OpenSSL을 사용합니다.

학원 DHCP로 IP가 바뀌면 복제가 끊길 수 있습니다. 네트워크 담당자와 사용 가능한 주소·유지 방식을 먼저 확인하고, 임의로 다른 PC 주소를 고정하지 않습니다.

## 1. PC1에서 로컬 파일과 인증서 준비

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action prepare-primary -Role pc1
```

생성 결과:

- `.env.shared-pc`: IP·포트만 보관하는 로컬 설정. 현재 확인된 주소가 기본값입니다.
- `.secrets/shared-pc/pc1`: PC1 root 비밀번호·서버 인증서와 복제 비밀번호.
- `.secrets/shared-pc/pki`: CA 개인키. PC1의 보호된 위치에 보관하며 컨테이너나 PC2에 전달하지 않습니다.
- `.secrets/shared-pc/pc2-transfer`: PC2로만 전달할 인증서·키·복제 비밀번호.

화면의 `CA_FILE_SHA256`를 기록합니다. 비밀번호는 화면에 출력하지 않습니다. 기존 파일은 자동 덮어쓰기하지 않으며 일부 생성에 실패하면 남은 파일을 직접 점검합니다. 인증서 유효 기간은 서버·클라이언트 90일, CA 365일입니다. 만료 전에 운영 중단/교체 절차를 별도로 준비해야 합니다.

## 2. PC1의 연결 범위 확인

네트워크 담당자와 PC1의 TCP 3306을 PC2에서만 접근하도록 정합니다. 관리자 PowerShell에서 사용할 좁은 허용 규칙 예시는 다음과 같습니다.

```powershell
New-NetFirewallRule -DisplayName 'Telecom MySQL PC2 to PC1' -Direction Inbound -Action Allow -Protocol TCP -LocalAddress 192.168.3.18 -LocalPort 3306 -RemoteAddress 192.168.3.19 -Profile Any
```

이 규칙 하나를 추가해도 기존의 넓은 Docker/3306 허용 규칙을 덮어쓰지는 않습니다. 네트워크 담당자가 기존 규칙까지 확인하고 다른 학원 PC에서 접근되지 않는지 별도로 검증해야 합니다. 스크립트는 방화벽을 자동 변경하지 않습니다. 실제 복제 계정에는 PC2 전용 인증서의 subject/issuer와 별도 비밀번호가 모두 필요하며, 호스트 NAT의 실제 출발지 주소에 의존하지 않습니다.

## 3. PC1 MySQL 실행·최초 초기화

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action up -Role pc1
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action bootstrap-primary -Role pc1
```

최초 초기화는 프로젝트 DB에 테이블이 없는 경우에만 허용합니다. 이미 데이터·복제 계정이 있으면 초기화를 중단하고 스냅샷 기반 절차로 전환합니다. 데이터 삭제·GTID 리셋·기존 계정 비밀번호 변경은 하지 않습니다. 앱 담당자의 Migration은 이 초기 복제 확인이 끝난 뒤 Primary에서 한 번 실행합니다.

## 4. PC2에 전용 파일 전달

PC1의 `.secrets/shared-pc/pc2-transfer` **폴더만** USB 등 신뢰할 수 있는 비공개 경로로 PC2에 복사합니다. 예를 들어 PC2의 아래 경로에 둡니다.

```text
C:\Users\user\telecom-security-project\.secrets\incoming\pc2-transfer
```

공개 GitHub·이슈·채팅에 파일 내용이나 비밀번호를 올리지 않습니다. CA 개인키·PC1 root 비밀번호·PC1 서버 개인키는 전달하지 않습니다. 두 PC에서 실행하는 Windows 계정만 `.secrets`를 읽을 수 있게 관리하고 네트워크 공유로 공개하지 않습니다.

PC2에서 실행:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action prepare-replica -Role pc2 -TransferDirectory C:\Users\user\telecom-security-project\.secrets\incoming\pc2-transfer
```

PC2가 출력한 `CA_FILE_SHA256`가 PC1에서 기록한 값과 같은지 직접 비교합니다. PC2 root 비밀번호는 이 PC에서 따로 생성됩니다. 파일 출처나 해시가 다르면 연결을 진행하지 않습니다.

## 5. PC2에서 포트 확인·Replica 연결

```powershell
Test-NetConnection 192.168.3.18 -Port 3306
```

`TcpTestSucceeded : True`가 먼저 나와야 합니다. 실패 시 PC1 컨테이너·주소·포트·방화벽부터 확인합니다. ping 성공만으로 TCP 3306 통신이 확인된 것은 아닙니다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action up -Role pc2
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action connect-replica -Role pc2
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action status -Role pc2
```

Replica는 앱 DB·계정을 별도로 초기화하지 않고 Primary의 GTID에서 받습니다. 최초 연결은 빈 DB에서만 허용하며, 기존 채널이 있으면 설정 일치를 확인하고 보존합니다. `read_only`와 `super_read_only`를 영속 설정합니다. MySQL은 초기 구성 후 재시작하면 같은 채널로 다시 연결합니다. Docker Desktop 자체의 Windows 로그인/시작 동작과 무인 재부팅은 아직 별도 확인이 필요합니다.

정상 기대값:

```text
server_id / GTID / read_only / super_read_only: 2 ON 1 1
receiver / error: ON 0
applier: ON
max worker error: 0
host / port / GTID / TLS / identity verification: mysql-primary.telecom.test 3306 1 YES YES
```

서버 이름은 PC2 컨테이너의 extra_hosts를 통해 PC1 IP로 해석됩니다. Windows hosts나 시스템 인증서 저장소는 변경하지 않습니다. 에러 메시지 전체에는 SQL·계정 해시가 들어갈 수 있어 status는 상태와 오류 번호만 출력합니다.

## 6. 실제 두 PC의 합성 데이터 복제 검증

PC1:

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action write-probe -Role pc1
```

출력한 `PROBE_ID=...`에서 GUID를 복사해 PC2 명령의 값으로 넣습니다. GUID는 합성 검증 행 식별자입니다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action verify -Role pc2 -ProbeId 여기에-PC1에서-출력한-GUID
```

`PASS`는 해당 행 복제, 검증 TLS 설정, 읽기 전용 플래그 및 Replica root 쓰기의 ERROR 1290 거절을 확인한 것입니다. 앱 계정·로그인·앱 Migration 검증은 별도입니다. 이 결과를 받기 전 실제 두 물리 PC 간 복제가 통과했다고 표시하지 않습니다.

## 7. 종료·재시작·문제 보고

각 PC의 역할에 맞게 중지합니다. 데이터·비밀번호·인증서를 보존합니다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/shared-pc.ps1 -Action stop -Role pc1
# PC2에서는 -Role pc2 사용
```

재개는 각 PC에서 `up`을 사용한 뒤 PC2의 `connect-replica`, `status`, 새 probe 검증으로 확인합니다. `down -v`, Docker factory reset, 무조건적인 RESET REPLICA/GTID 리셋은 하지 않습니다. 자동 DB 승격·DB VIP·백업·예약 작업은 이번 도구에 포함하지 않습니다.

이상 발생 시 담당 PC, 실행한 Action, 오류 번호, 마스킹한 상태만 공유합니다. 개인키·비밀번호·SQL 전체 오류·전체 Compose config를 붙여넣지 않습니다. 자료를 Git에 넣기 전 `git check-ignore .env.shared-pc .secrets/shared-pc/pc1/root-password`로 제외 여부를 확인합니다.

## 검증 범위와 다음 작업

인프라 개발 PC에서 두 개의 독립 Compose 프로젝트를 별도 Docker 네트워크에 연결해 시험합니다. 이는 실제 학원망·두 Windows 호스트·Windows 방화벽·DHCP·Docker Desktop 재부팅 동작의 검증을 대신하지 않습니다. 실행 결과는 [검증 기록](infra-verification.md)에 남깁니다.

개발 PC에서 재현하는 통합 시험은 다음 명령입니다. Docker 네트워크와 임시 프로젝트 2개를 생성하며 공용 PC IP에는 접속하지 않습니다. 테스트 포트는 loopback 13318이고 완료 후 자신이 만든 컨테이너·네트워크만 정리합니다. 조사 가능한 볼륨·인증서는 보존하므로 반복 시험으로 디스크를 무제한 사용하지 않습니다.

```powershell
powershell -NoProfile -ExecutionPolicy RemoteSigned -File tests/integration/shared-pc-smoke.ps1
```

실제 두 PC 복제 통과 후: 앱용 최소 권한 계정·TLS 연결 설정 → 앱 Migration/연동 → Windows Docker 환경의 암호화 백업·분리 복원 → Nginx·앱 분산 → 관제·k3s/VIP 적용 여부 순서로 진행합니다. 앱 초안은 최신 main에 있으나 이번 DB 실습 변경에서 앱 실행 완료를 선언하지 않습니다.

근거: [Docker Desktop 공개 포트](https://docs.docker.com/desktop/features/networking/), [MySQL 복제 TLS·서버 이름 검증](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html).
