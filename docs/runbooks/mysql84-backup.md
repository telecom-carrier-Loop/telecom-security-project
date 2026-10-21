# 기존 프로젝트 MySQL 수동 백업과 격리 복구 시험

## 적용 상태와 범위

2026-10-21 PC1 `flask_mysql` → PC2 `mysql-lab`의 TLS·GTID 복제 연결과 PC2 읽기 전용 설정을 확인했다. 검증 테이블의 행 추가·컬럼 추가·수정·삭제가 PC2에 반영된 현장 결과도 확인했다. 이후 현장 수동 백업과 격리 복구 시험에서 22개 테이블 CHECK TABLE OK, 행 수 보고서 저장, `restore-verified`, 시험 컨테이너 정상 종료까지 확인했다. 사용자는 백업을 다른 위치에도 보관했다.

`infrastructure/tools/mysql84-backup.ps1`은 **PC2에서** 실행한다. `.secrets/mysql84-replication/pc2/state.json`의 `replica-ready` 상태와 실제 이미지·컨테이너·볼륨을 확인한다. 라이브 DB 복원이나 자동 장애 전환 도구가 아니다. 기존 원본·복제 DB는 유지한다. 수동 root 인증과 백업 계정의 저장된 자격 증명 인증을 지원한다. 예약은 별도 [1시간 주기 백업 도구](mysql84-backup-schedule.md)로 등록·검증한다.

## 1. 백업 준비

- Docker Desktop, PC1·PC2 MySQL과 복제는 실행 상태로 유지한다. 기존 컨테이너를 수동 종료하지 않는다.
- 백업 중에는 PC1의 테이블 생성·변경·삭제·이름 변경·TRUNCATE와 스키마 마이그레이션을 잠시 중지한다. InnoDB 일반 데이터 쓰기는 단일 트랜잭션 스냅샷과 병행할 수 있다.
- MySQL 콘솔에서는 `exit;`로 나온 뒤 PC2 PowerShell에서 실행한다. 현재 PC2 root 비밀번호가 필요하다.

## 2. 수동 백업

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-backup.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Backup
```

현재 PC2 root 비밀번호를 두 번 입력한다. 첫 번째는 실제 역할·읽기 전용·복제 스레드·적용 오류·InnoDB 테이블 목록 확인, 두 번째는 `mysqldump`다. root 비밀번호를 파일이나 명령 인수에 저장하지 않는다.

단일 트랜잭션으로 앱 DB와 routines/events/triggers를 덤프한다. 테이블 목록, 덤프 완료 표식, SHA256을 확인한 뒤에만 완성 파일과 manifest를 발행한다. 테이블 수는 현재 DB에서 읽으므로 이후 테이블이 추가돼도 22개로 고정하지 않는다. 지원하는 테이블 이름은 영문·숫자·밑줄이며 이름 첫 글자는 영문 또는 밑줄이다.

정상 메시지:

```text
PASS: backup saved; ... base tables, SHA256 and completion marker checked.
```

저장 위치는 다음과 같다. 실제 생성 경로도 콘솔에 출력한다.

```text
C:/Users/user/telecom-security-project/.secrets/backups/mysql84/pc2/
  latest.json
  <실행 시각과 난수>/
    snapshot.sql
    manifest.json
    state.json
```

부가 검사 SQL과 메타데이터도 같은 실행 폴더에 보관한다. `.partial`만 남고 PASS가 없으면 정상 백업으로 취급하지 않는다. `latest.json`은 최근 실행 위치이며 실패한 실행도 기록될 수 있다. 과거 실행 폴더는 자동 삭제하지 않는다.

이 백업은 `--set-gtid-purged=OFF`인 **데이터 복구용**이다. 초기 복제 시드의 GTID 포함 스냅샷과 용도가 다르다. PC2에 반영된 스냅샷을 백업하므로 PC1 최신 쓰기와의 차이는 복제 지연에 영향을 받는다. MySQL 시스템 계정·권한은 앱 DB 덤프에 포함되지 않는다.

## 3. 격리 복구 시험

백업 PASS 후 실행한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-backup.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action RestoreTest
```

추가 root 입력 없이 별도 난수 비밀번호를 사용한다. 호스트에서는 실행 폴더의 `restore-private`에 보관하며 Docker 인수에는 비밀번호 파일 경로만 전달한다. MySQL 클라이언트 설정은 컨테이너 내부의 권한 600 복사본으로 사용한다. 이 폴더를 공개하거나 Git에 추가하지 않는다.

도구는 다음 순서로 진행한다.

1. 기존 manifest와 SQL의 SHA256을 다시 검사한다.
2. 실제 PC2의 고정 이미지 ID를 재사용하고 별도 데이터 볼륨을 만든다. 시험 컨테이너는 `loop-mysql84-restore-...`, 메모리 상한 1GB, `--network none`, 포트 미공개, 자동 재시작 없음이다.
3. 원본·라이브 볼륨과 다른지 검사하고 MySQL PID 1과 8.4.11/server_id=9032 준비 상태를 최대 120초 확인한다.
4. 다른 UUID와 복제 채널 없음까지 검사한 뒤 **시험 컨테이너에서만** 앱 DB를 생성·복원한다.
5. manifest에 기록된 모든 테이블의 `CHECK TABLE` 결과가 OK인지 검사하고 실제 복원 행 수를 조회한다.
6. `restore-report.txt`를 저장하고 시험 컨테이너만 정상 종료한다. 정상 종료까지 확인한 뒤 `restore-verified`와 최종 PASS를 기록한다. 볼륨과 백업은 보관한다.

정상 메시지:

```text
PASS: isolated restore verified; ... tables CHECK TABLE OK; row counts saved.
```

`loop_rows=테이블명` 뒤 숫자는 **복원된 백업의 행 수**다. 시험 중 라이브 데이터가 바뀔 수 있으므로 현재 PC1의 행 수와 항상 같다는 의미는 아니다. 이 시험은 SQL 복원·기본 테이블 무결성·조회 가능성을 확인하며 앱 로그인·저장 프로시저/트리거의 계정 권한 등 전체 업무 기능 검증은 별도다.

## 오류와 상태 확인

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-backup.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Status
```

오류 시 실패 액션과 이 상태 출력을 확인한다. SQL 백업, 상태/로그 전체, 인증 파일을 공개하지 않는다. `mysql-lab`이나 원본 볼륨을 삭제하지 않는다. 격리 복구 실패 후 `RestoreTest`를 재시도하면 동일한 검증용 컨테이너·볼륨에만 다시 적용한다. 이미 정상 검증한 백업은 다시 복원하지 않고 이전 완료 상태를 안내한다.

## 이후 작업

현장 수동 백업·복구 PASS 다음에 전용 백업 계정을 준비하고, 비대화형 백업 실행을 검증한 뒤 Windows 작업 스케줄러를 구성한다. `Backup` 액션은 root 비밀번호를 두 번 입력하므로 그대로 예약하지 않는다. 아래 `BackupSaved` 액션의 현장 검증이 다음 단계다. 자동 예약·보관 정리·별도 장치 복사는 아직 포함하지 않는다. 다른 폴더가 같은 물리 디스크에 있다면 PC2 디스크 장애 대비 사본은 아니므로 별도 장치 여부도 구분한다.

### 다음 단계: 백업 전용 계정 준비

PC2의 `super_read_only`는 유지한다. PC1에서 새 계정을 생성하고 현재 복제 경로로 PC2에 반영한다. 계정 관리 문장은 statement 형식으로 기록되고 현재 데이터베이스를 기준으로 필터링하므로 **같은 세션에서 `USE my_new_board_db`를 먼저 실행**한다. 여기서 계정은 두 PC 모두에 생기며 컨테이너 내부 로컬 소켓으로만 사용할 `loop_backup@localhost`다. Flask 계정이나 복제 계정으로 사용하지 않는다.

1. PC1 PowerShell에서 `docker exec -it flask_mysql mysql --user=root --password`, PC2 PowerShell에서 `docker exec -it mysql-lab mysql --user=root --password`로 각각 접속한다. 각 PC의 root 비밀번호를 입력한다. 두 MySQL 콘솔에서 다음 조회를 실행한다.

```sql
SELECT @@server_id AS server_id,
       @@read_only AS read_only,
       @@super_read_only AS super_read_only,
       @@partial_revokes AS partial_revokes;
SELECT COUNT(1) AS existing_backup_accounts
FROM mysql.user WHERE User = 'loop_backup';
```

PC1은 `1 / 0 / 0 / 0`, PC2는 `2 / 1 / 1 / 0`, 계정 수는 양쪽 모두 0이어야 한다. 기존 계정이 있거나 역할·partial_revokes 설정이 다르면 아래 생성 명령을 실행하지 말고 결과를 먼저 확인한다. PC2에서 `SHOW REPLICA STATUS\G`도 확인하여 IO/SQL Running=Yes, Last IO/SQL Errno=0이어야 한다. 두 PC에서 다른 관리자가 같은 계정을 동시에 만들지 않는다.

2. 조건을 만족하면 **PC1 MySQL 콘솔에서만** 실행한다. `sql_log_bin` 조회는 1이어야 한다. 0이면 여기서 중단한다.

```sql
USE my_new_board_db;
SELECT @@SESSION.sql_log_bin AS session_binlog;
```

이어서 실행한다. 첫 명령이 반환하는 `Generated password`를 비공개로 보관하고, 오류가 나면 이후 명령을 중단한다. 생성 결과에는 비밀번호가 있으므로 화면이나 출력 전체를 공유하지 않는다.

```sql
CREATE USER 'loop_backup'@'localhost'
  IDENTIFIED WITH caching_sha2_password BY RANDOM PASSWORD
  PASSWORD EXPIRE NEVER;
GRANT SELECT, SHOW VIEW, TRIGGER, EVENT
  ON `my\_new\_board\_db`.* TO 'loop_backup'@'localhost';
GRANT SHOW_ROUTINE ON *.* TO 'loop_backup'@'localhost';
GRANT SELECT ON performance_schema.replication_connection_status
  TO 'loop_backup'@'localhost';
GRANT SELECT ON performance_schema.replication_applier_status
  TO 'loop_backup'@'localhost';
GRANT SELECT ON performance_schema.replication_applier_status_by_worker
  TO 'loop_backup'@'localhost';
GRANT SELECT ON performance_schema.replication_applier_status_by_coordinator
  TO 'loop_backup'@'localhost';
```

앱 DB 덤프와 복제 건강 상태 조회에 필요한 권한을 부여한다. DB 이름의 밑줄은 이스케이프하여 다른 이름에 대한 와일드카드 권한 부여를 막는다(partial_revokes=0 전제). SHOW_ROUTINE은 전체 저장 루틴 정의를 볼 수 있는 전역 권한이다. EVENT/TRIGGER는 백업에 필요하지만 객체 관리 권한도 포함하므로 이 계정을 순수 SELECT 전용이라고 부르지 않는다. 테이블 행 변경·복제 제어·서버 변수 변경·계정 관리 권한은 부여하지 않는다. FLUSH PRIVILEGES는 필요 없다.

3. PC2의 기존 root MySQL 콘솔에서 실행한다. 계정 반영이 아직 보이지 않으면 잠시 뒤 조회만 다시 실행한다. PC2에서 계정을 따로 생성하거나 읽기 전용을 해제하지 않는다.

```sql
SELECT User, Host, plugin
FROM mysql.user WHERE User = 'loop_backup';
SHOW GRANTS FOR 'loop_backup'@'localhost';
SELECT @@read_only AS read_only, @@super_read_only AS super_read_only;
SHOW REPLICA STATUS\G
exit;
```

`loop_backup / localhost / caching_sha2_password`, 위 권한들, 읽기 전용 `1 / 1`, 복제 IO/SQL Running=Yes 및 오류 번호 0을 확인한다. 복제 오류가 나면 계정 생성 전체를 재실행하거나 트랜잭션을 건너뛰지 않는다.

4. PC2 PowerShell에서 새 계정으로 실제 로컬 소켓 접속을 확인한다. 비밀번호는 PC1에서 생성된 백업 계정 비밀번호다.

```powershell
docker exec -it mysql-lab mysql --protocol=SOCKET --user=loop_backup --password --database=my_new_board_db
```

접속 후 실행한다.

```sql
SELECT CURRENT_USER() AS backup_account,
       @@server_id AS server_id,
       @@read_only AS read_only,
       @@super_read_only AS super_read_only;
SELECT COUNT(1) AS table_count
FROM information_schema.TABLES
WHERE TABLE_SCHEMA = 'my_new_board_db' AND TABLE_TYPE = 'BASE TABLE';
SHOW GRANTS;
exit;
```

기대값은 `loop_backup@localhost / 2 / 1 / 1`, 현재 스키마 기준 22개 테이블이다. 이후 스키마가 바뀌면 개수도 달라진다. **이 단계는 계정 준비까지만 완료하며 자동 백업 완료가 아니다.** 이후 비대화형 실행·종료 코드·결과 파일 검증을 통과한 도구를 PC2의 동일 Windows 사용자로 예약한다. Docker Desktop과 PC가 실행 중이어야 하며 절전·로그아웃 시 실행 가능 여부도 검증한다.

근거: [계정·권한 문장의 복제](https://dev.mysql.com/doc/refman/8.4/en/replication-features-mysqldb.html), [statement 형식의 기본 DB 필터](https://dev.mysql.com/doc/refman/8.4/en/replication-rules-db-options.html), [난수 비밀번호 생성](https://dev.mysql.com/doc/refman/8.4/en/create-user.html), [SHOW_ROUTINE으로 저장 루틴 백업](https://dev.mysql.com/doc/refman/8.4/en/privileges-provided.html#priv_show-routine).

### 권한 명령 복사 시 백틱·별표 누락

현장 입력에서 DB 이름의 백틱과 `*`가 누락되어 `Unknown command '\_'` 및 ERROR 1064가 발생했다. `GRANT SHOW_ROUTINE ON` 뒤의 `*.*`도 빠졌다. 뒤의 Performance Schema 권한 네 개는 Query OK였으므로 계정을 다시 만들거나 비밀번호를 변경하지 않는다. 경고 내용은 확인 전 정상·비정상으로 단정하지 않는다.

PC1 root MySQL 콘솔에서 `USE my_new_board_db;`를 실행하고 `SELECT @@server_id, @@SESSION.sql_log_bin;`가 `1 / 1`인지 확인한다. 아래는 빠진 두 권한만 재적용하며 복사 과정에서 사라진 문자를 CHAR로 생성한다. 입력 코드에는 백틱·역슬래시·별표가 없다. 이전 확인의 partial_revokes=0 전제는 유지한다. PREPARE 또는 EXECUTE 오류가 나면 다음 문장을 중단한다.

```sql
SET @loop_target = CONCAT(QUOTE('loop_backup'), '@', QUOTE('localhost'));
SET @loop_db = CONCAT(CHAR(96), REPLACE('my_new_board_db', '_', CONCAT(CHAR(92), '_')), CHAR(96));
SET @loop_sql = CONCAT('GRANT SELECT, SHOW VIEW, TRIGGER, EVENT ON ', @loop_db, '.', CHAR(42), ' TO ', @loop_target);
PREPARE loop_grant FROM @loop_sql;
EXECUTE loop_grant;
SHOW WARNINGS;
DEALLOCATE PREPARE loop_grant;
```

첫 블록이 성공하면 이어서 실행한다.

```sql
SET @loop_sql = CONCAT('GRANT SHOW_ROUTINE ON ', CHAR(42), '.', CHAR(42), ' TO ', @loop_target);
PREPARE loop_grant FROM @loop_sql;
EXECUTE loop_grant;
SHOW WARNINGS;
DEALLOCATE PREPARE loop_grant;
SHOW GRANTS FOR 'loop_backup'@'localhost';
```

위 두 블록의 SHOW WARNINGS는 바로 앞 EXECUTE의 경고를 확인한다. 기존 네 권한의 과거 경고를 복구하는 명령은 아니다. 권한 적용 후 PC2 root 콘솔에서 `SHOW GRANTS FOR 'loop_backup'@'localhost';`와 `SHOW REPLICA STATUS\G`를 확인하고 앞 절의 백업 계정 소켓 접속 시험을 진행한다. PC2 읽기 전용은 유지한다.

근거: [MySQL의 GRANT 준비 문장 지원](https://dev.mysql.com/doc/refman/8.4/en/sql-prepared-statements.html), [DB 권한 이름의 밑줄 이스케이프](https://dev.mysql.com/doc/refman/8.4/en/grant.html).

### 저장된 백업 계정으로 비대화형 실행

현장에서 PC2 `loop_backup@localhost` 접속, server_id=2, read_only/super_read_only=1/1, 22개 테이블 조회와 전체 덤프 권한 시험(`/dev/null` 출력) PASS를 확인했다. 양쪽 권한 7행과 복제 스레드·오류 없음도 확인했다. GRANT 시 `skip-name-resolve` 경고 1285가 나왔지만 실제 로컬 소켓 접속·조회·덤프 시험은 통과했으므로 이를 이유로 DB를 재시작하지 않는다. [같은 경고의 MySQL 보고](https://bugs.mysql.com/bug.php?id=97399), [로컬 소켓의 localhost 계정 매칭](https://dev.mysql.com/doc/refman/8.4/en/connection-access.html).

다음 명령은 수정된 도구를 받은 뒤 **PC2의 동일 Windows 사용자**로 실행한다. 관리자나 SYSTEM 등 다른 계정으로 바꾸지 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-backup.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action SaveCredential
```

입력할 값은 PC1에서 생성한 **loop_backup 계정 비밀번호 한 번**이다. root 비밀번호는 저장하지 않는다. `PSCredential`을 Windows DPAPI로 암호화하여 `.secrets/backups/mysql84/pc2/credentials/loop_backup.clixml`에 저장한다. 폴더 상속 권한을 제거하고 현재 사용자와 SYSTEM만 접근하도록 설정한다. 기존 자격 증명은 덮어쓰지 않는다. 이 단계의 PASS는 암호화 저장 확인이며 실제 인증 성공은 다음 단계에서 확인한다. [Microsoft Export-Clixml의 Windows 사용자·컴퓨터 종속 암호화](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.utility/export-clixml?view=powershell-5.1).

이어서 실행한다. 이번에는 비밀번호 입력이 없어야 한다. 스키마 마이그레이션은 백업 동안 중지한다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-backup.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action BackupSaved
```

저장된 자격 증명을 복호화하고 현재 사용자/SYSTEM 전용 임시 폴더에서 옵션 파일을 만든다. 컨테이너 내부 권한 700 작업 폴더에 복사해 파일 권한 600을 확인하며 로컬 소켓·loop_backup·지정 옵션 파일을 사용한다. 로그인 경로 파일을 비활성화하고 비밀번호를 프로세스 인수에 넣지 않는다. 호스트 평문 파일은 복사 후 정리하고 컨테이너 옵션 파일도 성공·실패 시 정리한다. 잘못된 비밀번호나 권한·복제 상태 오류는 root 또는 대화형 인증으로 전환하지 않고 실패한다. 컨테이너 인증 파일 정리에 실패한 경우도 `backup-failed`로 기록한다.

성공 기준은 `PASS: backup saved; ... base tables, SHA256 and completion marker checked.`와 `Stage: backup-ready`다. 수동 백업과 같은 데이터 복구용 manifest/SQL 형식을 사용한다. `.secrets`의 다른 과거 실행 폴더와 검증된 백업은 유지한다. SaveCredential·Backup·BackupSaved·RestoreTest는 파일 잠금으로 동시에 실행되지 않으며 Status는 상태 조회만 한다.

새 백업의 격리 복구 시험을 진행한다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-backup.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action RestoreTest
```

최종 `restore-verified`까지 확인하면 예약 작업 등록으로 진행한다. **현재 자동 예약은 미등록**이다. 이후 예약 실행도 같은 PC·Windows 사용자로 해야 하며 PC와 Docker Desktop이 실행 중이어야 한다. 암호화 파일을 다른 PC에 복사해도 그곳에서 사용할 수 없다. 입력 실수로 BackupSaved 인증이 실패하면 비밀번호나 인증 파일을 공개하지 말고 실패 액션과 Status만 확인한다.

Windows PowerShell 5.1 시험에서 실제 DPAPI 왕복·접근 권한, 따옴표·역슬래시·공백·제어 문자·유니코드의 옵션 파일 값 이스케이프, 비대화형 인수와 root 전환 없음, 임시 파일 정리 및 정리 실패, 저장 자격 증명 백업의 격리 복구 호환성, 중복 실행 차단을 검사한다. 이후 현장 PC2에서도 SaveCredential·BackupSaved와 새 백업의 RestoreTest PASS(22개 테이블)를 확인했다. 다음은 사용자가 지정한 [1시간 주기 예약 등록과 실제 예약 실행 검증](mysql84-backup-schedule.md)이다.

## 준비 확인 120초 시간 초과

초기 도구의 `sh -c` 준비 확인에는 중첩된 따옴표가 있었다. Windows PowerShell 5.1이 네이티브 명령에 인수를 전달할 때 이를 손실하는 문제를 실제 argv 검사 실행 파일로 재현했다. MySQL이 실행돼 있어도 SQL 전달 실패로 준비 판정이 나지 않을 수 있다. 수정본은 LF 형식의 `restore-ready.sh`와 `restore-ready.sql`을 시험 컨테이너에 복사하고 파일 경로만 전달한다. PID 1과 버전/server_id 검사는 유지한다.

백업 PASS 후 `Isolated MySQL did not become ready within 120 seconds`가 나왔다면 수정된 도구를 받고 **RestoreTest만 재실행**한다. 기존 백업과 같은 시험 컨테이너·볼륨을 재사용하므로 `Backup`이나 초기 복제 복원을 다시 하지 않는다. 복구 SQL이 라이브 `mysql-lab`에서 실행되는 경로도 추가하지 않는다.

수정본에서도 시간 초과가 나면 `Status`를 실행한다. 마지막 준비 확인 종료 코드와 시험 컨테이너의 상태·종료 코드·OOM 여부·시작 오류를 출력한다. 실제 서버 초기화 지연·자원 부족·접속 설정 문제는 이 정보로 구분해 추가 확인해야 한다. root 비밀번호나 원본 백업 SQL을 공유하지 않는다.

### Windows 공유 설정 파일 무시: ERROR 1045 / using password: NO

현장 진단에서 PID 1은 `mysqld`였지만 `/run/loop-restore/client.cnf` 권한이 `777`이었고, MySQL이 `World-writable config file ... is ignored`와 `Access denied ... (using password: NO)`를 출력했다. 비밀번호가 틀렸다는 증거가 아니라 설정 파일 자체를 읽지 않은 경우다.

수정 도구는 읽기 전용 Windows 공유 파일을 변경하지 않는다. 대신 `/tmp/loop-restore-auth` 디렉터리를 권한 700으로 만들고 설정 파일을 복사해 권한 600을 적용·확인한다. 준비 확인·복원·테이블 검사 모두 이 컨테이너 내부 파일을 사용한다. 같은 백업과 기존 시험 컨테이너에서 수정된 `RestoreTest`만 재실행한다. root 비밀번호 변경이나 백업 재생성은 필요 없다.

### 복원 이후 테이블 검사 또는 행 수 판정 실패

준비 확인과 SQL 복원 명령을 통과한 뒤 `Restored table check or row count failed`가 나오면 검사 결과 판정 단계에서 실패한 것이다. 초기 도구는 `CONCAT(...,CHAR(9),COUNT(1))`의 한 필드 안에 탭을 넣었는데, MySQL `--batch`는 필드 내부 탭을 실제 탭 대신 `\t`로 이스케이프하므로 행 수 정규식이 맞지 않았다.

수정본은 마커와 행 수를 별도 SQL 열로 조회하여 배치 출력의 열 구분자를 사용한다. `CHECK TABLE OK` 및 테이블별 유일한 숫자 행 수 검사는 유지한다. 검사 전 `restore-report.txt`를 저장하며, 실제 테이블 검사 실패와 행 수 형식 실패를 테이블명과 함께 구분해서 출력한다.

수정된 도구로 기존 백업의 `RestoreTest`만 재실행한다. 이전 SQL 복원 명령이 성공했어도 최종 검사를 통과하기 전에는 복구 시험 완료로 취급하지 않는다. 재실행에서도 실패하면 해당 오류와 `Status`를 확인하고, 원본 백업이나 라이브 DB를 초기화하지 않는다.

## 도구 검증

Windows PowerShell 5.1 Docker 대역 시험에서 잘못된/공유된 원본, 불건전 복제 검사, 덤프 실패·미완료·테이블 변경·GTID 혼입, SQL/manifest 변조, 라이브 볼륨 재사용, 포트 공개, 초기화·복원·테이블 검사·정상 종료 실패, 복구 재시도와 비밀번호 인수 노출을 검사한다. 공유 설정 파일 권한 777을 모사해 내부 700/600 권한 설정·확인, 내용 보존, 모든 클라이언트의 내부 파일 사용, 권한 확인 실패 시 복원 차단을 검사한다. 실제 네이티브 실행 파일로 기존 따옴표 손실과 수정된 파일 경로 인수 보존을 확인하며, 시간 초과 이후 새 컨테이너를 만들지 않고 재개되는 것도 검사한다. 실제 Docker/MySQL 동작과 복구 결과는 현장 실행으로 확인해야 한다.

참고: [MySQL mysqldump와 단일 트랜잭션·GTID 옵션](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html).

참고: [PowerShell 네이티브 명령 인수와 따옴표 전달](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_parsing#passing-arguments-that-contain-quote-characters).

참고: [MySQL의 쓰기 가능한 옵션 파일 무시 규칙](https://dev.mysql.com/doc/refman/8.4/en/option-files.html).

참고: [MySQL 배치 출력의 필드 내부 문자 이스케이프](https://dev.mysql.com/doc/refman/8.4/en/mysql-command-options.html).
