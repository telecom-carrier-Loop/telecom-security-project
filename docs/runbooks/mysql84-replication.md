# 기존 프로젝트 MySQL 8.4 복제 준비

## 확인된 상태

| 구분 | PC1 | PC2 |
|---|---|---|
| 주소 | 192.168.3.18 | 192.168.3.19 |
| 컨테이너 | flask_mysql | mysql-lab |
| MySQL | 8.4.11 | 8.4.11 |
| server_id | 1 | 2 |
| GTID / enforce_gtid_consistency | ON / ON, 영구 저장 | ON / ON, 영구 저장 |
| 프로젝트 DB | my_new_board_db, 22개 InnoDB 테이블 | my_new_board_db, 22개 테이블 |

이 절차는 기존 `flask_mysql`을 사용하는 프로젝트의 초기 동기화용이다. 빈 DB를 만드는 이전 `shared-pc.ps1` bootstrap이나 이전 5개/7개 테이블 백업을 사용하지 않는다. 정기 백업은 초기 동기화와 별도 작업으로 구성한다.

## PC1 인증서·계정·최신 백업 준비

Flask와 해당 DB에 쓰는 자동화를 잠시 중지한다. MySQL 컨테이너와 Docker Desktop은 유지한다. `mysql>`에서는 `exit;`로 나와 PowerShell에서 실행한다.

두 파일을 같은 디렉터리에 둔다. 저장소에 있는 파일을 실행하는 경우:

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Prepare
```

현재 PC1 root 비밀번호를 **네 번** 입력한다. 순서는 원본 확인, TLS 갱신·계정 생성·쓰기 잠금, mysqldump, 쓰기 재개다. root 비밀번호를 파일에 보관하지 않는다. 복제 비밀번호는 `SOURCE_PASSWORD` 제한에 맞춰 32자(접두사 4자 + 난수 14바이트의 28자리 hex)로 생성하며 SQL 파일과 `.secrets` 안에 보관하고 명령 인수에 넣지 않는다.

도구는 다음 작업을 수행한다.

1. 검증된 업그레이드 상태의 실제 PC1 컨테이너·볼륨과 GTID·22개 InnoDB 테이블을 확인한다. 기존 `loop_repl` 계정이나 쓰기 잠금이 있으면 중단한다.
2. **기존 CA와 CA 개인 키를 PC1 안에서 유지**하며 PC1 IP와 localhost를 확인할 수 있는 새 서버 인증서와 PC2 전용 클라이언트 인증서를 발급한다. 기존 서버 인증서·키는 별도 보관한다.
3. 서버 인증서를 갱신하고 `loop_repl` 계정에 `REPLICATION SLAVE`만 부여한다. 비밀번호와 `/CN=loop-pc2-replica` 클라이언트 인증서가 모두 필요하다. Docker Desktop의 주소 변환을 고려해 MySQL Host는 `%`이며 PC1 방화벽의 PC2 주소 제한을 함께 사용한다. 계정 생성은 세션의 바이너리 로깅을 꺼서 다른 서버로 전달하지 않는다.
4. 실제 TLS 연결에서 서버 신원과 클라이언트 인증을 검사한다. 서버는 192.168.3.18과 127.0.0.1을 인증서 SAN으로 포함한다.
5. PC1 쓰기를 잠근 상태에서 GTID 정보가 포함된 새 앱 DB 백업을 생성한다. 테이블 개수, GTID 구문, 덤프 완료 표식을 검사하고 파일 SHA256을 계산한다.
6. 아래 PC2 전달 폴더를 완성하고 PC1 쓰기 잠금을 해제한다. 새 스냅샷 이후 변경은 복제가 연결되면 바이너리 로그에서 이어받아야 한다.

```text
C:\Users\user\telecom-security-project\.secrets\mysql84-replication\pc1\pc2-transfer
  snapshot.sql
  ca.pem
  client-cert.pem
  client-key.pem
  replication-password
  manifest.json
```

출력의 `MANIFEST_SHA256` 값은 따로 기록한다. 전달 폴더에는 업무 데이터, 클라이언트 개인 키, 복제 비밀번호가 있으므로 신뢰할 수 있는 비공개 경로로 PC2에 전달한다. GitHub·공개 채팅에 업로드하지 않는다. **이 폴더만 전달**하고 부모 폴더, 기존 서버 개인 키와 CA 개인 키는 PC1에 보관한다.

PC2에서는 아래 경로에 폴더를 배치한다. PC2의 기존 데이터 볼륨과 실행 인수를 확인한 뒤 백업·초기 복원·복제 채널 설정을 진행한다. 현재 준비 도구는 PC2 데이터를 변경하거나 복제를 시작하지 않는다.

```text
C:\Users\user\telecom-security-project\.secrets\mysql84-replication\incoming\pc2-transfer
```

## 오류와 상태 조회

`Prepare`를 다시 실행해 인증서·계정·기존 백업을 덮어쓰지 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Status
```

백업 또는 TLS 연결 확인 도중 오류가 나면 PC1이 쓰기 잠금 상태일 수 있다. 초기 내보내기가 중단된 상태에서 PC1 쓰기만 재개해야 하는 경우 다음 명령을 사용한다. 불완전한 전달 폴더를 정상 백업으로 표시하지는 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action ResumePrimary
```

정상 완료 기준은 `Stage: export-ready`, `PrimaryResumed=true`, 전달 폴더와 해시 출력이다. 이는 **PC1 준비 완료**이며 PC2 복제 성공을 의미하지 않는다.

## 검증

Windows PowerShell 5.1에서 Docker 대역을 이용해 잘못된 볼륨, 공유 볼륨, SQL 실패, TLS 실패, 덤프 실패·누락, 재실행 차단, 해시와 비밀 전달 범위를 검사한다. 실제 OpenSSL로 CA·서버·클라이언트 인증서를 생성하여 IP·용도 검사와 잘못된 IP 거부도 확인한다. 실제 DB 연결과 백업은 공용 PC에서 실행 결과를 확인한다.

참고: [MySQL GTID 초기 구성](https://dev.mysql.com/doc/refman/8.4/en/replication-gtids-howto.html), [암호화 복제 연결](https://dev.mysql.com/doc/refman/8.4/en/replication-encrypted-connections.html).

## PC2 초기 복원과 복제 연결

현재 PC2는 `mysql-lab`, 실제 서버 버전 8.4.11, 기본 bridge, 3306 공개, 데이터 볼륨 하나인 구성이다. `mysql:8` 태그를 새로 받지 않고 컨테이너의 실제 이미지 ID를 재사용한다. PC2 Flask와 DB에 쓰는 자동화는 중지한다. PC1의 준비를 다시 실행하지 않는다.

1. PC1의 **pc2-transfer 폴더만** 위의 PC2 incoming 경로로 복사한다. PC1 콘솔의 `MANIFEST_SHA256`을 별도로 준비한다. 부모 폴더와 CA·서버 개인 키를 복사하지 않는다. 부분 덤프의 전체 GTID 포함 경고는 예상된 것으로, PC2에서는 앱 DB만 복제하도록 필터를 영구 지정한다.
2. PC2 PowerShell에서 아래 `Stage`를 실행한다. 해시를 붙여넣고 **현재 PC2 root 비밀번호**를 입력한다. 해시·파일 무결성·PC2 UUID·GTID·22개 InnoDB 테이블을 먼저 검사한다. 원본을 정상 종료하고 원본 볼륨을 읽기 전용으로 마운트해 별도 볼륨에 복사한다. 복사본은 네트워크와 포트를 차단한 상태로 시작한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Stage
```

3. 복사본 MySQL이 준비될 때까지 약 15초 후 `Restore`를 실행한다. 현재 PC2 root 비밀번호를 입력한다. **원본이 아닌 격리된 복사본에서만** 바이너리 로그·GTID를 초기화하고 `my_new_board_db`를 PC1 스냅샷으로 대체한다. PC2 계정과 root 비밀번호는 유지한다. 쓰기 잠금을 영구 저장한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Restore
```

4. PASS 이후 `Activate`를 실행한다. 원본 이름은 `mysql-lab-before-replication-...`로 보존하고 복원된 볼륨을 사용하는 새 `mysql-lab`을 3306으로 공개한다. 기존 원본과 격리 검증 컨테이너는 모두 중지 상태로 유지한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Activate
```

5. 약 15초 후 `Start`를 실행한다. 실제 PC1 UUID와 TLS 인증서를 확인한 후 GTID 자동 위치·서버 인증서 검증·PC2 클라이언트 인증을 사용하는 채널을 생성한다. 현재 PC2 root 비밀번호를 입력한다. 시작 요청 PASS는 복제 완료 판정이 아니다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Start
```

6. 약 10초 후 `Verify`를 실행하고 현재 PC2 root 비밀번호를 입력한다. PC1에서 관측한 GTID까지 최대 30초 대기하고 수신·적용 스레드, worker/coordinator 오류, 읽기 전용 설정을 확인한다. 통과한 뒤에만 자동 재시작 정책을 저장한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Verify
```

성공 기준은 `Stage: replica-ready`, `Replica_IO_Running: Yes`, `Replica_SQL_Running: Yes`, 두 Last_*_Errno=0, `Auto_Position: 1`, `read_only=1`, `super_read_only=1`이다. 이후 PC1에서 작은 테스트 데이터를 변경하고 PC2에서 반영을 확인한다. PC2의 Flask 쓰기 연결도 PC1을 사용해야 하며 PC2 로컬 DB에는 직접 쓰지 않는다.

### 오류 발생 시

오류가 난 단계에서 중단하고 상태를 확인한다. `Stage`·`Activate`를 처음부터 반복하거나 원본 볼륨을 삭제하지 않는다. `Verify`에서 단순 지연이 난 경우 스레드 오류를 확인한 후 `Verify`만 재시도한다. 로그/SQL/상태 파일 전체에는 민감 정보가 포함될 수 있으므로 공개하지 않는다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Status
```

### 이후 테이블 변경과 백업

복제 필터는 `--replicate-do-db=my_new_board_db`로 컨테이너에 영구 저장한다. DDL은 ROW 형식에서도 기본 DB를 기준으로 필터링되므로 **PC1에서 `USE my_new_board_db;`를 먼저 실행한 후** 테이블 생성·변경·삭제를 수행한다. 마이그레이션의 기본 DB도 동일하게 지정한다. 계정 관리는 `mysql`을 기본 DB로 사용하는 별도 관리 작업으로 진행한다.

복제는 삭제·잘못된 수정도 전달하므로 정기 백업을 대체하지 않는다. 복제 반영 시험 다음에 별도 저장소로 정기 덤프, 보관 기간, 격리 복구 시험, 수동 장애 전환을 구성한다. 이 도구는 자동 승격·자동 원복을 수행하지 않는다.

PC2 도구 검증은 Windows PowerShell 5.1의 Docker 대역으로 진행한다. 전달 파일 변조, 잘못된/공유 볼륨, SQL 실패, 비정상 종료, 포트 충돌, 잘못된 복원 대상, TLS 실패, 빈 GTID, 재실행 차단, 성공 전 재시작 정책 차단을 검사한다. 실제 공용 PC2에서의 SQL 실행·통신 검증은 현장 실행 결과로 확인해야 한다.

참고: [DB 복제 필터의 DDL 규칙](https://dev.mysql.com/doc/refman/8.4/en/replication-options-replica.html#option_mysqld_replicate-do-db), [복제 연결 상태 컬럼](https://dev.mysql.com/doc/refman/8.4/en/performance-schema-replication-connection-configuration-table.html).

## 복제 연결 후 실제 데이터·DDL 반영 시험

2026-10-21 현장 PC2에서 비밀번호 수정 후 `Start`와 `Verify` PASS를 확인했다. server_id=2, read_only=1, super_read_only=1이며 수신·적용 스레드와 관측 GTID 반영 검사를 통과했다. 이는 연결 검증 완료이며 정기 백업·복구 훈련 완료를 의미하지 않는다.

검증 전용 테이블로 생성·추가·구조 변경·수정·삭제 반영을 시험한다. 각 PC의 MySQL 콘솔을 열고 아래 순서로 번갈아 실행한다. PC2에 직접 스키마나 데이터를 만들지 않는다. 동명 테이블이 이미 있어 CREATE가 실패하면 중단하고 기존 테이블의 용도를 확인한다.

PC1 PowerShell:

```powershell
docker exec -it flask_mysql mysql --user=root --password --default-character-set=utf8mb4
```

PC2 PowerShell:

```powershell
docker exec -it mysql-lab mysql --user=root --password --default-character-set=utf8mb4
```

1. PC1 MySQL에서 생성·추가:

```sql
USE my_new_board_db;
CREATE TABLE _loop_infra_repl_probe_20261021 (
    probe_id INT NOT NULL PRIMARY KEY,
    marker VARCHAR(64) NOT NULL
) ENGINE=InnoDB;
INSERT INTO _loop_infra_repl_probe_20261021 (probe_id, marker)
VALUES (1, 'created-on-pc1');
```

2. PC2 MySQL에서 조회. probe_id=1, marker=created-on-pc1이어야 한다. 지연이면 잠시 기다린 후 조회만 재시도한다.

```sql
USE my_new_board_db;
SELECT probe_id, marker FROM _loop_infra_repl_probe_20261021;
```

3. PC1 MySQL에서 컬럼 추가·데이터 수정:

```sql
USE my_new_board_db;
ALTER TABLE _loop_infra_repl_probe_20261021 ADD COLUMN checked_at DATETIME NULL;
UPDATE _loop_infra_repl_probe_20261021
SET marker='updated-on-pc1', checked_at=UTC_TIMESTAMP()
WHERE probe_id=1;
```

4. PC2 MySQL에서 조회. checked_at 컬럼과 값, marker=updated-on-pc1을 확인한다.

```sql
SELECT probe_id, marker, checked_at FROM my_new_board_db._loop_infra_repl_probe_20261021;
```

5. 확인 후 PC1 MySQL에서 검증 테이블을 삭제한다.

```sql
USE my_new_board_db;
DROP TABLE _loop_infra_repl_probe_20261021;
```

6. PC2 MySQL에서 삭제 반영 확인. 결과는 0이어야 한다.

```sql
SELECT COUNT(1) AS probe_tables_remaining
FROM information_schema.TABLES
WHERE TABLE_SCHEMA='my_new_board_db'
  AND TABLE_NAME='_loop_infra_repl_probe_20261021';
```

오류가 나거나 변경이 계속 반영되지 않으면 후속 DDL·삭제를 실행하지 말고 PC2 `SHOW REPLICA STATUS\G`의 IO/SQL 상태와 오류 번호를 확인한다. 정상 완료 후 두 MySQL 콘솔에서 `exit;`로 나온다. 이후 순서는 수동 백업 → 새 볼륨·격리 컨테이너 복구 시험 → 실제 저장소·계정 조건에 맞춘 정기 백업 예약 → 별도 장치 복사·보관 정책 → 수동 장애 전환 훈련이다. 초기 전달 스냅샷은 이미 존재하지만 정기 백업 예약과 복구 가능성 검증은 별도다.

Flask 담당자는 모든 앱 쓰기가 PC1 DB를 향하도록 설정한다. Docker로 옮긴 Flask에서 `127.0.0.1`은 Flask 컨테이너 자신이며 PC1 MySQL 주소를 뜻하지 않는다. PC2의 로컬 MySQL은 읽기 전용 복제본으로 유지한다.

### ERROR 3056: 기존 68자 복제 비밀번호 수정

이전 도구가 생성한 68자 비밀번호는 MySQL `CHANGE REPLICATION SOURCE TO ... SOURCE_PASSWORD`의 32자 제한 때문에 거부된다. `Restore`와 `Activate`가 PASS이고 `Start`에서 3056 오류가 난 경우 DB 복원·포트 전환은 완료된 상태다. `Prepare`·`Stage`·`Restore`·`Activate`를 다시 실행하지 않는다.

1. **PC1**에서 수정된 `mysql84-primary-export.ps1`을 받고 아래 액션을 실행한다. 현재 PC1 root 비밀번호를 한 번 입력한다. 완료된 원본 번들 무결성, 실제 PC1 신원과 전용 인증서 계정을 검사한 뒤 복제 계정 비밀번호만 기존 난수의 앞 32자로 변경한다. 계정 변경은 세션의 바이너리 로깅을 꺼서 복제하지 않는다. TLS 로그인을 실제 검사한다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-primary-export.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action FixReplicationPassword
```

2. **PC2**에서 수정된 `mysql84-replica.ps1`을 받고 `Start`, `Verify`만 차례로 실행한다. 각각 PC2 root 비밀번호를 입력한다. 수정 도구는 동일한 앞 32자를 사용하도록 TLS 접속 파일을 갱신하고 복제 채널에 적용한다. 실패 당시의 `replication-starting` 상태에서 재개할 수 있다.

```powershell
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Start
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File infrastructure/tools/mysql84-replica.ps1 -RepositoryPath C:/Users/user/telecom-security-project -Action Verify
```

원본 전달 폴더의 비밀번호 파일은 기존 번들을 검증하는 시드로 유지한다. 기존 파일·스냅샷·인증서·manifest SHA256을 수정하거나 재전달하지 않는다. 구버전의 68자 파일을 직접 편집하면 무결성 검사가 실패한다. 앱 DB·앱 계정·root 비밀번호도 바꾸지 않는다. 새로 준비하는 번들은 처음부터 32자이므로 이 수정 액션이 필요 없다.

검증에는 신규 비밀번호 길이/형식, 기존 68자 번들의 계정 수정과 해시 보존, 반복 수정, 계정 검사 실패, 변조 거부, MySQL의 32자 초과 거부를 모사하는 채널 검사, 기존 실패 단계에서 복원 없이 `Start` 재개가 포함된다. 실제 현장 연결 결과는 PC1 수정과 PC2 재개 후 확인한다.

참고: [MySQL SOURCE_PASSWORD의 32자 제한](https://dev.mysql.com/doc/refman/8.4/en/change-replication-source-to.html).
