# 기존 프로젝트 MySQL 수동 백업과 격리 복구 시험

## 적용 상태와 범위

2026-10-21 PC1 `flask_mysql` → PC2 `mysql-lab`의 TLS·GTID 복제 연결과 PC2 읽기 전용 설정을 확인했다. 검증 테이블의 행 추가·컬럼 추가·수정·삭제가 PC2에 반영된 현장 결과도 확인했다. 다음 단계는 실제 SQL 백업과 격리 복원이다.

`infrastructure/tools/mysql84-backup.ps1`은 **PC2에서** 실행한다. `.secrets/mysql84-replication/pc2/state.json`의 `replica-ready` 상태와 실제 이미지·컨테이너·볼륨을 확인한다. 라이브 DB 복원이나 자동 장애 전환 도구가 아니다. 기존 원본·복제 DB는 유지한다.

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

추가 root 입력 없이 별도 난수 비밀번호를 사용한다. 시험 비밀번호는 실행 폴더의 `restore-private`에만 보관하며 Docker 인수에는 비밀번호 파일 경로만 전달한다. 이 폴더를 공개하거나 Git에 추가하지 않는다.

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

현장 수동 백업·복구 PASS 다음에 전용 백업 계정, 실제 백업 저장 장치, 실행 주기·보관 기간을 정하고 Windows 작업 스케줄러를 구성한다. 현재는 수동 실행이며 자동 예약·보관 정리·별도 장치 복사는 포함하지 않는다. `.secrets`의 같은 디스크 백업만으로 PC2 디스크 장애를 대비할 수 없으므로 별도 장치 보관도 다음 단계에서 검증한다.

## 도구 검증

Windows PowerShell 5.1 Docker 대역 시험에서 잘못된/공유된 원본, 불건전 복제 검사, 덤프 실패·미완료·테이블 변경·GTID 혼입, SQL/manifest 변조, 라이브 볼륨 재사용, 포트 공개, 초기화·복원·테이블 검사·정상 종료 실패, 복구 재시도와 비밀번호 인수 노출을 검사한다. 실제 Docker/MySQL 동작과 복구 결과는 현장 실행으로 확인해야 한다.

참고: [MySQL mysqldump와 단일 트랜잭션·GTID 옵션](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html).
