# MySQL 복제·백업·복구: k3s 웹 이전 영향 점검

기준일: 2026-10-22 KST. [오늘의 웹 배포 기록](../operations/2026-10-22-k3s-web-handoff.md)과 저장소 도구를 대조했다. 이 변경은 문서 정리와 정적 점검이다. 라이브 MySQL·예약 작업·Kubernetes 설정을 수정하거나 승격·복원을 실행하지 않았다.

## 결론

웹 실행 위치가 Windows/Ubuntu의 개발 프로세스에서 Ubuntu k3s Pod로 바뀌었다. MySQL은 기존 Windows Docker에 남아 있다. **이유 없이 복제를 초기화하거나 DB 볼륨을 옮길 필요는 없다.** 기존 복제·격리 복구의 안전 장치는 유지한다.

반면 DB 접속 설정의 반영 대상, 원격 앱 계정, 승격 후 백업 역할, Kubernetes 설정 복구 절차는 새 구조에 맞춰 보완해야 한다. 현재 확인된 것은 복제·백업·격리 복구의 과거 PASS와 오늘의 PC1 DB 연결이다. PC2 승격·앱 쓰기 대상 변경·원복의 통합 성공을 확인한 증거는 없다.

## 확인된 기준

| 구분 | 현재/과거 확인값 | 오늘의 추가 확인 |
|---|---|---|
| Primary | PC1 Windows `192.168.3.18:3306`, `flask_mysql`, MySQL 8.4.11 | 두 노드의 Pod TCP, 두 Flask Pod Ready·업무 조회 |
| Replica | PC2 Windows `192.168.3.19:3306`, `mysql-lab`, server_id 2, 읽기 전용 | 오늘 복제 지연·스레드 상태의 새 출력은 없음 |
| 복제 | TLS·GTID, 앱 DB `my_new_board_db` 필터, 10-21 데이터·DDL 반영 PASS | 웹 배치 변경만으로 채널을 재생성하지 않음 |
| 백업·복구 | PC2의 1시간 예약 실제 실행·22개 테이블 격리 RestoreTest PASS | 오늘 최신 예약 실행 여부는 별도 Status 확인 필요 |
| 앱 설정 | `telecom/telecom-runtime` + `telecom/telecom-api-secrets` → Flask 환경변수 | 기존 접속 계정 `root`, DB_HOST `192.168.3.18` |
| 앱 복제본 | `telecom-api` 두 개, 공통 DB 접속 설정 | PC1·PC2 각각 Ready 확인 |

## 수정 필요 여부

| 항목 | 현재 판단 | 조치 |
|---|---|---|
| MySQL 컨테이너·볼륨·GTID 복제 | 웹 이전만으로 변경 불필요 | 현장 신원과 최신 복제 상태를 확인하고 그대로 유지 |
| 데이터 백업·격리 복구 | DB 위치·역할·컨테이너 신원이 같으면 유지 가능 | 새 백업이 정상 완료되는지 확인; 라이브 DB에 RestoreTest를 적용하지 않음 |
| 앱 DB 설정 반영 | 보완 필요 | Windows `.env` 편집 대신 ConfigMap·Secret과 Flask rollout을 대상으로 함 |
| PC1 전체 장애와 DB 전환 | 제어부 장애까지 포함해 설계 필요 | PC1에 DB Primary와 유일한 k3s Server가 함께 있으므로 장애 후 ConfigMap 갱신·rollout을 당연히 실행할 수 있다고 가정하지 않음 |
| 앱 DB 계정 | 외부 공개 전 보완 필요 | root 사용을 앱 전용 계정으로 전환하고 두 DB의 계정·비밀번호·권한·접속 출발지를 확인 |
| PC2 Primary 승격 후 예약 백업 | 역할 대응 설계 필요 | 기존 도구는 정상 Replica 전용; 보호 조건을 삭제하지 말고 Primary 백업 모드/전환 절차를 별도 구현·시험 |
| DB 주소/경로 변경 | 변경하는 경우에만 필요 | 복제 연결 주소·TLS SAN·계정 호스트·방화벽·앱 Secret/ConfigMap을 함께 점검 |
| 재해 복구 자료 | 보완 필요 | DB 덤프 외 앱 버전·Kubernetes 비밀/일반 설정·TLS·배포 파일·k3s 복구 수단을 별도 보호 |
| 모니터링·실제 업무 검증 | 새 경로에서 추가 확인 | 웹 readiness뿐 아니라 복제 지연·백업 나이·로그인·세션·승인된 쓰기/복제 반영 검사 |

## 1. DB 자체는 유지하고 접근 경계를 다시 확인

`mysql84-replica.ps1`은 실제 `mysql-lab`, 이미지·볼륨·역할 상태, GTID·TLS와 쓰기 잠금을 확인한다. 웹이 Pod로 바뀐 것만으로 `Stage`, `Restore`, `Activate`, `Start`를 처음부터 재실행할 근거는 없다. 초기 복제 시드는 현재 데이터를 대체하는 절차이므로 장애 전환 명령처럼 사용하지 않는다.

두 노드 Pod에서 현재 PC1 DB로의 접속은 성공했다. 다만 성공만으로 MySQL이 어떤 출발지 IP와 `user@host` 계정을 선택했는지는 확정하지 못한다. 앱 전용 계정을 만들 때 각 노드에서 `USER()`, `CURRENT_USER()`와 서버 측 연결 정보를 확인하고 최소 필요한 접근 범위를 정한다. 무조건 Pod CIDR이나 `%`를 허용값으로 확정하지 않는다.

PC1→PC2 복제 경로와 Pod→DB 경로는 별개다. pfSense/노드 방화벽 변경 후에는 두 경로를 각각 재검증한다. 노드 IP `192.168.7.x`를 Windows DB 주소 `192.168.3.x` 대신 사용하지 않는다.

## 2. `.env` 수정만으로 현재 웹의 DB 대상은 바뀌지 않음

현재 `backend/app/config.py`는 `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`로 URI를 만든다. `DATABASE_URL` 하나를 추가하는 방식은 현재 설정에 반영되지 않는다.

Flask Deployment는 `envFrom`으로 `telecom-runtime`과 `telecom-api-secrets`를 읽는다. 따라서 Windows 또는 VM의 `.env`만 바꾸고 기존 Flask 프로세스를 재시작해도 실행 중인 Kubernetes 앱의 접속 대상은 바뀌지 않는다. 현장 설정을 처음 등록했던 Python 블록도 당시 `.env`를 읽어 복사한 일회성 실행이며 지속 동기화 기능이 아니다. 옛 `.env`로 다시 실행하면 Kubernetes 설정을 옛 대상으로 되돌릴 수 있다.

ConfigMap·Secret 변경 후에는 새 Pod가 필요하다. 변경 전 현재 설정과 롤백 자료를 보호 경로에 남기고, DB 쓰기 주체가 하나임을 보장한 상태에서 전환한다. DB 승격 승인·역할 확인·네트워크 검증을 먼저 완료한 뒤 사용하는 적용 단계는 다음과 같다. 이것만으로 DB 승격이 수행되는 것은 아니다.

```bash
# PC1 Ubuntu: 검증된 설정 변경을 마친 후에만 실행
sudo k3s kubectl -n telecom rollout restart deployment/telecom-api
sudo k3s kubectl -n telecom rollout status deployment/telecom-api --timeout=180s
sudo k3s kubectl -n telecom get pods -l app=telecom-api -o wide
```

공통 envFrom 설정이므로 두 Flask Pod 모두를 확인해야 한다. DB 대상 변경만이라면 React 이미지를 다시 빌드할 필요는 없다. `pool_pre_ping`·연결 재활용은 끊긴 연결 처리이며 새 Primary 선택·승격·설정 갱신을 대신하지 않는다.

**PC1 DB 컨테이너 장애와 PC1 물리 PC 전체 장애를 구분한다.** DB만 장애이고 k3s Server가 살아 있으면 위 설정 갱신·rollout 절차를 사용할 수 있다. PC1 전체가 꺼지면 유일한 API server도 사라져 PC2 Agent만으로 ConfigMap 변경이나 새 rollout을 수행할 수 없다. 현재 앱은 DB IP를 환경변수로 고정해서 사용한다. 따라서 PC2 DB를 승격하는 것만으로 남은 웹 Pod의 DB 대상이 자동으로 바뀌지 않는다. PC 전체 장애 대응을 목표로 하면 제어부 가용성 또는 사전에 준비한 외부의 안정된 DB 진입점·동일 앱 자격 증명·이름 해석 생존 조건 등을 함께 설계해야 한다. 현재 구현/검증 완료로 보지 않는다.

`mysql84-cutover.ps1`의 `configure`는 로컬 `.env`에 `127.0.0.1`과 `loop_app`을 기록하고 로컬 Flask 재시작을 안내한다. 이 파일은 MySQL 버전 전환용 과거 도구로 실제 운영 컨테이너 신원·단계도 따로 검사한다. k3s 앱 설정기나 PC2 장애 승격기로 재사용하지 않는다.

## 3. root 대신 앱 계정 준비, Replica 자격 증명 확인

오늘 사용한 계정은 root다. 외부 공개 전에는 앱 DB에 필요한 SELECT/INSERT/UPDATE/DELETE 등 실제 기능에 필요한 권한만 부여한 앱 계정으로 전환한다. Migration/운영 계정은 별도로 유지한다. 이번 문서 변경에서 계정을 생성하거나 권한을 부여하지 않았다.

`mysql84-replica.ps1`의 초기 복원은 PC2의 기존 root 계정을 보존한다. 현재 Kubernetes Secret의 root 비밀번호는 PC1 접속 설정에서 가져왔다. 두 PC의 root 비밀번호가 같다고 가정하면 안 되며, **DB_HOST만 PC2로 바꾸면 인증이 실패할 수 있다.** 동일 앱 자격 증명을 쓸지, 승격 시 Secret도 바꿀지 명시적으로 결정하고 양쪽에서 확인한다.

현재 앱 DB 필터가 MySQL 시스템 계정·권한의 동기화를 항상 보장한다고 가정하지 않는다. 계정 관리 문장의 바이너리 로그·기본 DB·복제 필터 조건을 확인하고, 변경 후 두 서버에서 해당 계정과 권한이 실제로 존재하는지 검증한다. 기존 [백업 계정 준비 절차](mysql84-backup.md)의 `USE my_new_board_db` 조건을 다른 계정 작업에 무조건 생략하거나 그대로 일반화하지 않는다.

## 4. 승격하면 기존 백업 도구의 전제가 바뀜

`mysql84-backup.ps1`은 다음을 확인한 뒤 백업한다.

- PC2 상태 파일의 `Stage=replica-ready`.
- 기존 `mysql-lab` 컨테이너 ID·이미지 ID·라이브 데이터 볼륨·단독 사용.
- MySQL 8.4.11, server_id 2, 기대한 서버 UUID, GTID 설정.
- `read_only=1`, `super_read_only=1`.
- 기대한 PC1 UUID를 source로 하는 복제 연결·적용 스레드의 정상 상태와 오류 없음.

PC1 장애로 복제가 비정상이거나 PC2를 쓰기 가능한 Primary로 승격하면 이 조건을 통과하지 못할 수 있다. 이는 잘못된 대상의 백업을 막는 보호 동작이다. 쓰기 잠금/복제 검사/UUID 확인을 단순히 제거하지 않는다.

승격을 운영 범위에 넣으려면 역할별 백업 정책과 도구를 별도로 설계한다. Primary 모드에서도 서버·볼륨 신원, 단일 쓰기 주체, InnoDB·스냅샷 완성도, SQL·manifest 무결성과 격리 복구 검사를 유지해야 한다. 언제 Replica 백업을 멈추고 어느 Primary에서 새 백업을 시작하는지도 정해야 한다.

예약은 저장소 스크립트를 직접 실행하지 않고 `.secrets/backups/mysql84/pc2/scheduler/`의 고정 사본과 SHA256을 검증한다. Git pull로 도구를 수정해도 고정 백업 사본은 자동 갱신되지 않는다. `Repair`는 검증된 기존 설치의 **스케줄러 worker**를 교체할 수 있지만 백업 도구 사본까지 자동 교체하지 않는다. 추후 백업 도구 개정에는 두 사본·해시·설정·예약 실행·격리 복구의 일관된 갱신/롤백 절차가 필요하다. 고정 파일을 수동 덮어쓰거나 해시 검사만 끄지 않는다.

웹만 k3s로 옮겼으므로 지금 예약을 재등록하거나 백업 계정을 다시 만들 필요는 없다. Windows PC2의 사용자·프로필·Docker 경로와 DB 신원이 유지되는지 확인한다. 저장된 DPAPI 자격 증명은 원래 Windows 사용자/PC 조건에 묶이므로 Ubuntu Secret으로 대체하거나 다른 PC에 단순 복사하지 않는다.

## 5. DB IP·pfSense 경로가 바뀌는 경우

오늘의 웹 이전만으로 복제 인증서를 재발급할 필요는 없다. 하지만 DB 호스트 주소를 실제로 바꾸면 다음을 함께 확인한다.

- 앱 ConfigMap/Secret의 새 대상과 두 API Pod의 연결.
- 복제 `SOURCE_HOST`와 PC1/PC2 실제 통신 경로, GTID 이어받기와 복제 상태.
- `mysql84-primary-tls.sh`의 서버 SAN은 현재 `192.168.3.18`, `127.0.0.1`, 기존 DNS 이름을 포함하도록 작성돼 있음. 새 주소가 기존 인증서에 없으면 신원 검증을 유지하는 방식으로 인증서/이름을 갱신해야 함.
- 앱 계정·복제 계정에 적용되는 실제 출발지와 NAT/방화벽 허용 범위.
- 역할·서버 UUID·컨테이너/볼륨 신원이 달라지는 경우의 상태 파일·백업 계정 재검증. 과거 state.json을 다른 서버용으로 수동 조작하지 않음.

복제 TLS가 활성화됐다는 사실은 Flask→MySQL 연결도 TLS라는 증거가 아니다. 현재 앱 URI에는 별도 TLS 접속 인수가 없고 이 경로의 암호화는 미검증이다. 네트워크 설계에서 필요 조건을 정하고 별도 구현·검증한다.

## 6. 데이터 복구와 서비스 전체 복구의 차이

기존 덤프는 `my_new_board_db`의 데이터 복구용이며 `--set-gtid-purged=OFF`다. 초기 GTID 복제 시드를 대체하지 않는다. 시스템 계정·권한, Kubernetes Secret/ConfigMap, k3s 상태, 웹 이미지·소스 버전, TLS 인증서를 모두 복구하는 백업은 아니다.

다음 자료를 대응되는 버전으로 별도 보호해야 한다.

| 자료 | 관리 방법 |
|---|---|
| DB SQL·manifest·복구 보고서 | 기존 비공개 백업 경로와 무결성 검사 유지 |
| 앱 계정·토큰·DB 비밀번호·향후 TLS 키 | Git 외부의 접근 제한·보호된 복구 자료; 평문 Secret export를 공개하지 않음 |
| 일반 설정·현장 Deployment·Nginx 설정 | 버전 관리 가능한 비밀 없는 사본과 변경 기록 |
| 웹 이미지·소스·DB 스키마 버전 | 일치하는 릴리스 태그/검증 digest, 이미지 복구 수단 |
| 단일 k3s Server 상태·재구축 수단 | 실제 datastore 유형에 맞춘 별도 복구 설계; SQLite 구성을 확인하지 않고 etcd 전용 절차를 적용하지 않음 |
| Windows 예약·DPAPI 계정 조건 | 원래 계정·경로·고정 도구 버전과 재발급/재설치 절차 |

격리 RestoreTest PASS는 데이터 파일의 복원·테이블 검사 결과다. 라이브 앱 자동 복구, 최신 시점 복구(PITR), PC2 자동 승격이나 원복의 성공 증거가 아니다. 복구한 시점의 `auth_sessions` 등으로 돌아가면 이후 생성된 세션은 없어질 수 있어 재로그인이 필요할 수 있다. 실제 복구 훈련에는 두 API Pod의 로그인·승인된 업무 쓰기·복제 재구성 검사를 추가한다.

사용자 보관 범위는 2026-10-20~2026-11-12, 별도 저장장치는 없는 것으로 확인됐다. 1시간 주기·자동 삭제 없는 누적 보관을 유지하되 PC2 디스크 장애 대비 외부 사본은 미확보다. 범위의 마지막 날짜가 자동 예약 중지나 자동 삭제를 뜻하지 않는다.

## 7. 수동 장애 전환 훈련에 추가할 순서

아래는 설계/검토 순서이며 지금 라이브 DB에서 실행할 승격 명령 묶음이 아니다.

1. 실제 장애 범위와 최신 백업·GTID·복제 지연을 확인하고 비동기 복제의 손실 가능 범위를 판단한다.
2. 업무 쓰기를 중지/통제하고 구 Primary의 쓰기를 확실히 차단(fencing)한다. Kubernetes 외에 남아 있는 개발 Flask·Windows 컨테이너·n8n 등 다른 쓰기 주체도 확인한다.
3. PC2를 새 Primary로 사용할 조건과 계정·권한·데이터 최신성을 확인하고 승인된 승격 절차를 수행한다. 이 도구 집합에는 통합 자동 승격이 구현돼 있지 않다.
4. 제어부가 살아 있는 장애 시나리오에서는 Kubernetes DB 대상과 필요한 Secret을 갱신하고 두 Flask Pod를 재생성한다. PC1 전체 장애는 위에서 설명한 별도 설계 없이는 이 절차를 그대로 수행할 수 없다. 전환 중 옛/새 DB에 동시에 쓰지 않도록 통제한다.
5. 두 Pod가 같은 새 DB의 올바른 UUID/server_id와 쓰기 역할을 사용하는지 확인하고 로그인·승인된 쓰기를 검증한다. `SELECT 1` readiness만으로 쓰기 가능 Primary를 판정하지 않는다.
6. 백업 역할을 새 구조에 맞춰 전환하고 새 백업·격리 복구·예약 실행을 검증한다.
7. 구 PC1이 복귀해도 바로 쓰기를 켜지 않는다. 새 Primary 기준 재동기화와 역방향 복제/계획된 원복 절차를 별도 검증한다.

## 지금 가능한 읽기 점검

### PC2 Windows PowerShell: 예약 상태

```powershell
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File 'C:/Users/user/telecom-security-project/.secrets/backups/mysql84/pc2/scheduler/mysql84-backup-schedule.ps1' -RepositoryPath 'C:/Users/user/telecom-security-project' -Action Status
```

과거 PASS를 오늘 최신 백업으로 간주하지 말고 마지막 성공 시각·실제 파일·로그를 확인한다. 이 명령은 새 백업이나 복원을 실행하지 않는다. PC·Docker·사용자 로그온 조건이 충족되지 않는 동안 매시간 백업이 계속 생성되는 것은 아니다.

### PC2 Windows PowerShell → MySQL: 복제 상태

```powershell
docker exec -it mysql-lab mysql --user=root --password
```

```sql
SHOW REPLICA STATUS\G
SELECT @@server_id, @@read_only, @@super_read_only;
```

원하는 기준은 수신/적용 스레드 정상, 복제 오류 없음, PC2의 두 읽기 전용 값 1이다. 지연 숫자 하나만으로 최신 데이터 일치를 확정하지 않는다. 전체 복제 상태 출력에는 운영 정보가 있으므로 그대로 공개 첨부하지 않는다.

## 점검한 근거와 참고

- 저장소: `backend/app/config.py`, Kubernetes base의 `api-deployment.yaml`, `runtime-config.yaml`.
- 저장소: `mysql84-cutover.ps1`의 로컬 env configure, `mysql84-replica.ps1`의 PC2 계정 보존·DB 필터·역할 검증.
- 저장소: `mysql84-backup.ps1`의 source identity·Replica guard·격리 복구, `mysql84-backup-schedule.ps1`의 고정 사본·hash·Repair.
- 기존 [복제](mysql84-replication.md), [백업·격리 복구](mysql84-backup.md), [예약](mysql84-backup-schedule.md) 현장 기록.
- [Kubernetes ConfigMap: 환경변수 변경은 Pod 재시작 필요](https://kubernetes.io/docs/concepts/configuration/configmap/).
- [Kubernetes Secret](https://kubernetes.io/docs/concepts/configuration/secret/).
- [MySQL 8.4 장애 전환 시 source 변경](https://dev.mysql.com/doc/refman/8.4/en/replication-solutions-switch.html).
