# PC2 승격 후 백업 모드 준비

2026-10-28 마감 갱신: **PC2 Primary 전환 및 API 연결, Primary 백업·25개 테이블 격리 복원·실제 예약 실행을 확인했다.** [현장 인계](../operations/2026-10-28-pc2-primary-handoff.md)에 최종 결과와 역방향 복제 후속 작업을 기록했다. 이 도구 자체는 승격이나 앱 연결 변경을 수행하지 않는다. 아래 Replica 전제와 Primary 거절 시험은 승격 전 준비 당시의 기록이다. [예약·Discord 절차](mysql84-primary-schedule.md)를 함께 확인한다.

## 확인된 현장 전제

- PC1 Primary server_id1, PC2 Replica server_id2, GTID·복제 IO/SQL 정상.
- PC2 최신 백업25개 테이블 격리 복원 성공, `restore-verified`.
- PC2 `webuser@172.17.0.1` 준비. 두 API Pod가 PC2에 별도 연결해 server_id2/read_only1/super_read_only1 및 users11행 조회 성공.
- PC2 3306 허용 원본:127.0.0.1,192.168.3.19,192.168.7.100,192.168.7.185. 일반PC192.168.3.21은TCP접근차단.
- PC2 webuser는 별도 자동생성 비밀번호를 사용한다. 실제 앱 전환 시 DB_HOST뿐 아니라 DB_PASSWORD도 PC2 값으로 바꾸어야 한다. 비밀번호를 Git/명령 인수/대화에 올리지 않는다.
- `loop_backup@localhost`는 계정잠금N. SHOW ROUTINE, 앱DB SELECT/SHOW VIEW/EVENT/TRIGGER, 복제 상태 performance_schema 4개 테이블 SELECT를 확인했다. 쓰기/승격/관리자 권한 추가는 불필요하다.

## 모드와 상태 분리

`infrastructure/tools/mysql84-backup.ps1`에 명시적 `-SourceRole Replica|Primary`를 추가했다. 기본값은Replica로 기존 예약 작업과 호환된다.

| 모드 | SQL 사전 조건 | 기록 위치 |
|---|---|---|
| Replica(기본) | 기존UUID/server_id2/version/GTID, read_only1/super_read_only1, 지정원본UUID의IO·SQL ON, 적용오류없음, InnoDB | `.secrets/backups/mysql84/pc2/` |
| Primary | 같은PC2 UUID/server_id2/version/GTID, read_only0/super_read_only0, binlog/log_replica_updates ON, 모든복제IO·SQL OFF, 적용오류없음, InnoDB | `.secrets/backups/mysql84/pc2-primary/` |

두 모드가 같은 PC2 컨테이너를 쓰므로 기존Replica의`operation.lock`을 공유한다. 저장된`loop_backup` DPAPI 자격 증명도 기존PC2 경로에서 재사용한다. 새root자격증명을저장하지않는다. 컨테이너·이미지·원래볼륨의기존정체성검사를유지한다. 원래복제구축state의`replica-ready`는출처확인용체크포인트이며현재SQL역할은매번별도검사한다.

새manifest에SourceRole을기록하고다른역할의복원작업공간으로섞지않는다. 이전SourceRole없는manifest는Replica로취급한다. 기존Replica시험컨테이너이름도유지한다.

**Primary 조건 통과는 다른 Primary가 차단됐다는 증거가 아니다.** 구Primary fencing, 최종동기화, 승격허가, 앱전환과복귀절차는별도다. 이도구는쓰기/복제설정을변경하지않고그상태를검사할뿐이다.

## 현재 Replica에서 실행할 사전검사

PC2에서 검토한 새도구를 `$loopRoleBackup`, 기존저장소를 `$loopRepo`로지정한다. 설치된예약worker를덮어쓰지않는다. `PreflightSaved`는저장자격증명으로SQL조회만하고덤프나복원을하지않는다. 검사결과는별도preflight폴더에저장하지만기존latest.json은갱신하지않는다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopRoleBackup" -RepositoryPath "$loopRepo" -Action PreflightSaved -SourceRole Replica
if ($LASTEXITCODE -ne 0) { throw 'Replica backup preflight failed. Do not promote.' }
```

기대값: `PASS: Replica backup preflight; 25 base tables...`(테이블수는실제DB기준).

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopRoleBackup" -RepositoryPath "$loopRepo" -Action PreflightSaved -SourceRole Primary
if ($LASTEXITCODE -eq 0) { throw 'Unexpected Primary preflight success. Inspect the actual DB role.' }
```

현재Replica에서는 **BACKUP_PRIMARY_NOT_READY에따른실패가기대값**이다. 단순파일없음/로그인실패/권한오류/다른실패를역할거절성공으로처리하지않는다. 오류표식과실제read_only1/1·IO/SQL Yes를함께확인한다. 검사실패후기존Replica백업/예약/Discord는계속유지한다.

## 실제 승격 후에만 실행할 명령

**지금 실행하지 않는다.** fencing·최종동기화·승격과역할별운영계획이완료된뒤의명령예시다.

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File "$loopRoleBackup" -RepositoryPath "$loopRepo" -Action BackupSaved -SourceRole Primary
if ($LASTEXITCODE -ne 0) { throw 'Primary backup failed. Do not run RestoreTest.' }
powershell -NoLogo -NoProfile -ExecutionPolicy RemoteSigned -File "$loopRoleBackup" -RepositoryPath "$loopRepo" -Action RestoreTest -SourceRole Primary
if ($LASTEXITCODE -ne 0) { throw 'Primary isolated restore failed.' }
```

기존과같이테이블목록/완료표식/SHA256검사후발행하고별도network-none/포트미공개/원본볼륨분리컨테이너에서복원한다. 앱DB만덤프하며계정/권한·GTID재시드백업은아니다. 스키마변경중덤프하지않는다.

## 아직 필요한 작업

- 기존설치된예약worker/Discord감시경로는Replica전용으로유지한다. 별도Primary예약·감시코드는추가됐으나현장검증전이며자동전환됐다고표시하지않는다.
- [비활성등록과시험전송](mysql84-primary-schedule.md)을준비하고실제역할전환후Primary백업/격리복원·예약실행·실패알림을검증해야한다. 준비전에는승격하지않는다.
- 수동추가한PC2방화벽VM허용원본도후속정책도구에명시적으로반영해야한다. 기존Apply를임의로다시실행하지않는다.
- CoreDNS는PC1에만1개, 제어부도PC1단독이다. 전체PC1중단시험은별도준비후수행한다.

## 로컬 검증 범위

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File tests/integration/mysql84-backup-role-guards.ps1
```

9개Docker모의흐름으로기본Replica호환성, 역할별경로·manifest, 검사실패시덤프차단/완료발행금지, 공유잠금, 다른컨테이너/manifest거절, 검사시latest보존과임시인증파일정리를검증한다. SQL성공/실패는모의응답이므로실제MySQL조건과Primary덤프·복원성공을입증하지않는다. 실제자격증명이나학원Docker를사용하지않는다.

근거: [MySQL mysqldump](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html), [기존 백업·격리복원](mysql84-backup.md), [예약 백업](mysql84-backup-schedule.md).
