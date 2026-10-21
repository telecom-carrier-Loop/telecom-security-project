# PC1 실제 서비스 MySQL 8.0 → 8.4 업그레이드

## 확인된 대상

| 항목 | PC1 | PC2 |
|---|---|---|
| 컨테이너 | `flask_mysql` | `mysql-lab` |
| 현재 버전 | 8.0.46 | 8.4.11 |
| 앱 DB | `my_new_board_db` | `my_new_board_db` |
| 기본 테이블 | 22개, InnoDB | 22개, InnoDB |
| 기존 포트 | 3306 | 3306 |

PC1 데이터 볼륨은 `7_test_class_mysql_data`다. 기존 계정은 모두 `caching_sha2_password`다. Flask는 Windows에서 실행하며 5000, React는 5173을 사용한다.

이전 `mysql84-cutover.ps1`의 `mysql-server`와 5개/7개 테이블 백업은 이번 작업 대상이 아니다. 이전 상태 파일을 재사용하거나 덮어쓰지 않는다.

## 1. 복사본 업그레이드 준비

1. Flask를 `Ctrl+C`로 종료하고 다른 앱·자동화의 DB 쓰기도 중지한다. Docker Desktop과 원본 `flask_mysql`은 실행 상태로 둔다.
2. PC1 저장소에서 아래 도구를 실행한다. **PC2에서는 실행하지 않는다.**

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql80-stage.ps1 -RepositoryPath C:/Users/user/telecom-security-project
```

현재 PC1 root 비밀번호를 두 번 입력한다. 비밀번호는 SQL 파일이나 명령 인수에 저장하지 않는다.

도구는 실제 3306 공개 컨테이너·볼륨·8.0.46·22개 InnoDB 테이블·인증 플러그인을 확인한다. 복제 채널, 암호화 테이블스페이스, 예약 이벤트가 있으면 중단해 추가 검토를 받는다.

그다음 쓰기를 잠그고 현재 앱 DB를 새로 백업한다. SQL 백업과 SHA256을 `.secrets/mysql80-upgrade/`에 보관한 뒤 원본의 자동 재시작을 끄고 정상 종료를 확인한다. 원본을 읽기 전용으로 마운트해 새 볼륨으로 복사하고, 그 복사본만 MySQL 8.4.11로 시작한다.

원본 컨테이너와 원본 볼륨은 삭제하거나 이름을 바꾸지 않는다. 검사 컨테이너에는 외부 네트워크와 공개 포트가 없다. 기존 계정·비밀번호·모든 DB 파일이 복사되므로 Flask의 연결 설정을 바꿀 필요가 없다. 실제 웹 연결 재개는 다음 전환 단계에서 검증한다.

## 2. 복사본 확인

```powershell
$loopState = Get-Content -LiteralPath 'C:/Users/user/telecom-security-project/.secrets/mysql80-upgrade/state.json' -Raw | ConvertFrom-Json
docker exec -it $loopState.CandidateId mysql -u root -p
```

기존 PC1 root 비밀번호를 입력한다. 초기 업그레이드가 진행 중이면 잠시 뒤 이 접속 명령만 재시도한다.

```sql
SELECT VERSION() AS mysql_version;
SELECT COUNT(1) AS base_table_count
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE';

USE my_new_board_db;
CHECK TABLE
    alembic_version, auth_login_failures, auth_sessions,
    benefit_redemptions, benefits, incident_histories, invoices,
    ip_blocks, ip_whitelist, membership_accounts, membership_tiers,
    payment_events, payments, plans, point_transactions,
    security_audit_logs, security_incidents, subscriptions,
    support_replies, support_tickets, usage_records, users;
```

정상 기준은 버전 `8.4.11`, 테이블 `22`, 각 테이블의 검사 결과 `status / OK`다. `candidate-started`는 Docker 시작 명령 성공만 뜻하며 DB 업그레이드 검증 완료를 뜻하지 않는다.

검증 결과를 확인하기 전에는 Flask를 다시 켜거나 검사 컨테이너를 3306으로 전환하지 않는다. 다음 작업은 검증된 복사본의 실제 서비스 전환, Flask 연결 확인, PC2 복제 초기 동기화, 정기 백업과 별도 복원 시험 순서다. GTID와 PC2의 읽기 전용 설정은 해당 단계에서 적용한다.

## 3. PC1 서비스 전환

복사본에서 `8.4.11`과 22개 테이블 `OK`를 확인한 뒤 진행한다. MySQL 프롬프트에서는 `exit;`로 나오고 Flask와 DB에 쓰는 다른 프로그램은 계속 중지한다. 이번 단계는 PC1에서만 실행한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql80-activate.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Activate
```

기존 PC1 root 비밀번호를 한 번 입력한다. 도구는 원본·복사본의 볼륨 단독 사용, 이미지, 서버 인수, 백업 SHA256, 포트 충돌을 검사한다. 복사본의 쓰기 잠금을 저장하고 정상 종료한 뒤, 원본은 보관용 이름으로 변경한다. 원본 볼륨은 유지하며 업그레이드된 복사본 볼륨을 사용하는 새 `flask_mysql` 컨테이너를 3306에 공개한다. 충돌하는 다른 컨테이너나 Windows 프로세스를 자동 종료하지 않는다.

시작 완료 메시지가 나오면 약 20초 뒤 다음 검증을 실행한다. `Activate`를 다시 실행하지 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql80-activate.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Verify
```

기존 root 비밀번호를 입력한다. 실제 8.4.11·22개 InnoDB 테이블을 확인하고 PC1 쓰기를 허용한다. `read_only=0`, `super_read_only=0`을 검증한 뒤 자동 재시작 정책을 `unless-stopped`로 저장한다. 이 정책은 Docker Engine이 실행 중일 때 적용되며, Windows 로그인 시 Docker Desktop 실행은 별도로 필요하다.

초기 기동 중 접속 오류가 나면 `Verify`만 잠시 뒤 재시도할 수 있다. 그 외 오류는 다음 상태 조회 결과로 진단한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql80-activate.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Status
```

## 4. Flask·React 확인

PC1의 기존 DB 연결 정보는 `DB_HOST=127.0.0.1`, `DB_PORT=3306`, `DB_NAME=my_new_board_db`를 유지한다. 계정과 비밀번호도 복사본에 보존되어 있다. `.env` 내용이나 비밀번호를 외부에 공유하지 않는다.

```powershell
Test-NetConnection -ComputerName 127.0.0.1 -Port 3306 -InformationLevel Quiet
Set-Location -LiteralPath 'C:/Users/user/telecom-security-project/backend'
python app.py
```

포트 검사는 `True`여야 한다. Flask는 기존 가상환경에서 실행하며 5000 포트를 유지한다. 별도 창에서 기존 React 실행 방법으로 5173을 켠다. 브라우저에서 `http://localhost:5173`에 접속해 기존 계정 로그인, 목록 조회, 정상적인 테스트 데이터 생성과 재조회가 되는지 확인한다. 테이블 검사만으로 앱 동작까지 검증됐다고 판단하지 않는다.

기존 Compose 설정은 원본 8.0 이미지와 원본 볼륨을 참조할 수 있으므로 수정하기 전까지 **기존 MySQL 서비스의 `docker compose up`을 실행하지 않는다.** Docker Desktop에서는 새 `flask_mysql`만 사용하고, 보관 중인 원본과 검사 컨테이너는 중지 상태를 유지한다. Flask 실행부터 DB 쓰기가 발생할 수 있으므로 그 이후에는 원본 8.0으로 단순 복귀하지 않는다.

정상 동작 확인 뒤 PC2의 현재 `mysql-lab`을 백업하고, 서버 ID 구분·GTID·복제 계정과 TLS·PC1 스냅샷 초기 동기화·읽기 전용 설정·복제 검증을 순서대로 진행한다. PC1 데이터 변경이 복제되는 것과 독립적인 시점 백업·복원 시험은 각각 확인해야 한다.

## 오류 또는 중단

도구를 통째로 재실행하지 않는다. 오류 문구와 상태 파일의 `Stage`를 확인한다. SQL 백업·원본 볼륨·원본 컨테이너·상태 파일을 보관하며 `docker compose down -v`, 볼륨 삭제, 이전 전환 도구 실행을 하지 않는다.

검증 전 오류라면 원본으로 돌아갈 수 있다. 실행 중인 검사 컨테이너를 먼저 종료한 뒤 상태 파일의 `SourceId`에 해당하는 원본을 시작한다. 원본이 계속 실행 중이라면 복사본을 추가로 만들지 말고 root 세션에서 `SET GLOBAL super_read_only = OFF;`와 `SET GLOBAL read_only = OFF;`로 쓰기 잠금을 해제한다. 저장된 `SourceRestartPolicy`와 변경 전 종료 설정도 확인해 복구한다.

이 복귀 방법은 새 8.4 서버에서 앱 쓰기를 받기 전까지 적용된다. 서비스 전환 후 새 데이터가 생기면 원본 8.0으로 단순 복귀하지 않는다.

## 검증 범위

Windows PowerShell 5.1 문법과 Docker 대역을 사용한 실패·원본 보호·백업 개수·격리·재실행 방지 검사를 수행한다. 실제 PC1 업그레이드 성공은 위 SQL 결과로 확인한다.

MySQL 8.0에서 8.4로의 업그레이드와 정상 종료 요건은 [공식 업그레이드 경로](https://dev.mysql.com/doc/refman/8.4/en/upgrade-paths.html), [바이너리 업그레이드 절차](https://dev.mysql.com/doc/refman/8.4/en/upgrade-binary-package.html)를 따른다.
