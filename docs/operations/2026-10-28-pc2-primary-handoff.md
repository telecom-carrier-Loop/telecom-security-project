# PC2 Primary 전환과 역방향 복제 인계

기준: 2026-10-28 Asia/Seoul. 사용자가 제공한 현장 실행 결과와 화면을 근거로 작성했다. 비밀번호·토큰·개인키·백업 원본은 저장소에 포함하지 않는다.

## 오늘 마감 상태

| 대상 | 확인 결과 | 유지할 상태 |
|---|---|---|
| PC1 Windows / flask_mysql | 192.168.3.18, server_id=1, read_only=1, super_read_only=1 | 기존 Primary 쓰기 차단 유지. 역방향 복제는 아직 미설정 |
| PC2 Windows / mysql-lab | 192.168.3.19, server_id=2, read_only=0, super_read_only=0 | 현재 쓰기 가능한 Primary |
| 기존 PC1→PC2 채널 | STOP REPLICA 후 IO/SQL 모두 No | 중지 유지. skip_replica_start=ON 영속 설정 확인 |
| k3s API | 두 Pod 모두 PC2 DB와 webuser로 접속, server_id=2 및 0/0 확인 | DB_HOST=192.168.3.19 유지 |
| 공개 웹 | https://192.168.3.30 readiness 200/database ok, 사용자 보고로 웹 읽기·쓰기 확인 | pfSense HAProxy → k3s → PC2 DB |
| PC2 Primary 백업·Discord 감시 | 두 예약 작업 Ready, 예약 백업 실제 실행 성공 | Primary 작업 활성 상태 유지 |
| PC2 기존 Replica 백업·감시 | 두 예약 작업 Disabled | 비활성 유지 |

PC1·PC2 Ubuntu는 각각 192.168.7.185 / 192.168.7.100이다. PC1은 유일한 k3s control plane이며 현재 CoreDNS도 PC1에 배치되어 있다. 전체 PC1 전원 차단 시 서비스 유지까지 검증된 상태는 아니다.

## DB 전환과 보안 확인

- API를 0개로 줄이고 PC1의 read_only/super_read_only를 영속적으로 켠 뒤 활성 InnoDB 트랜잭션 0을 확인했다.
- 전환 기준 PC1 GTID는 `98e409fb-a5c6-11f1-8bc1-9f1aa3e284ef:1-298`이다. PC2에서 누락·추가 GTID가 없는 상태를 확인한 뒤 복제를 중지하고 승격했다. 이후 PC2에서 발생한 새 GTID는 정상적인 신규 쓰기이며 전환 전 기준과 단순 동일 비교하지 않는다.
- 두 API를 재개하여 PC2 Primary 접속을 확인했다. 사용 계정은 `webuser@172.17.0.1`, DB는 `my_new_board_db`다. 웹 계정과 DB 관리자 계정은 별개다.
- PC2 방화벽 `Loop-DBScope-PC2-MySQL-TCP`에 역방향 복제 출발지인 PC1 Windows `192.168.3.18`을 추가했다. 기존 loopback·PC2·두 VM 허용 주소를 유지했다.
- PC1 Windows→PC2:3306 TCP 성공, 일반 학원 PC 192.168.3.21→PC2:3306 차단을 확인했다. Any 허용으로 넓히지 않는다.
- 앱은 Deployment의 명시적 DB_HOST로 PC2를 사용한다. 이전 `telecom-runtime` ConfigMap에는 PC1 주소가 남아 있었으므로 다음 배포 전에 선언 설정과 실제 설정을 일치시켜야 한다.

## 백업·복원·알림

Primary용 사전검사, 수동 백업, 25개 테이블 격리 복원, 실제 Windows 작업 스케줄러 실행을 확인했다. Discord 시험 전송과 Primary 감시 활성화도 성공했다.

- 활성: `Loop-MySQL84-PC2-Primary-Hourly-Backup`, `Loop-MySQL84-PC2-Primary-Backup-Discord-Monitor`.
- 비활성: `Loop-MySQL84-PC2-Hourly-Backup`, `Loop-MySQL84-PC2-Backup-Discord-Monitor`.
- 마지막 예약 백업: `20261028-170856-713-c29699`, 완료 **17:08:58 KST**, 작업 결과 `0x00000000`, last-run/last-success 모두 success.
- 앞선 `20261028-154511-792-d9446` 백업은 25개 테이블 격리 복원 PASS를 확인했다. 마지막 17:08 백업 자체의 별도 복원 결과는 아직 확인하지 않았다.
- 백업은 PC2의 `.secrets/backups/mysql84/pc2-primary/`에 있다. GTID_PURGED를 생략한 데이터 복구용 덤프이므로 복제 재구축용으로 바로 사용하지 않는다. PC2 로컬 백업의 외부 사본 확보는 후속 작업이다.
- 예약 실행은 현재 Windows 사용자의 로그인, PC 및 Docker Desktop 실행이 필요하다. 전원 종료 시간에는 백업·감시도 실행되지 않는다.

## 역방향 TLS 준비와 적용

PC2의 기존 MySQL CA로 PC2 서버 인증서와 PC1 복제 클라이언트 인증서를 발급했다. 준비 위치는 컨테이너의 `/var/lib/mysql/.loop-reverse-tls-current` 포인터로 다시 조회한다. 이번 작업 디렉터리는 `/var/lib/mysql/.loop-reverse-tls.Ycxxu8`이다.

| 구분 | 결과 |
|---|---|
| PC2 서버 인증서 | CN=192.168.3.19, SAN=192.168.3.19·127.0.0.1·localhost·mysql-lab, serverAuth |
| PC1 클라이언트 인증서 | CN=loop-pc1-replica, clientAuth. PC1으로 전송·설치 전 |
| 검증 | CA 지문 일치와 openssl verify의 IP 검사 성공 |
| 적용 | PC2 서버 인증서·키 설치 및 mysql 소유권/권한 설정 후 ALTER INSTANCE RELOAD TLS 성공 |
| 실제 로드 결과 | Ssl_server_not_before=2026-10-28 07:32:08 GMT, not_after=2027-10-28 07:32:08 GMT |
| 원본 보관 | 작업 디렉터리의 original-server/에 기존 서버 인증서·키 보관 |

최초 설치 시 컨테이너에 cmp가 없어 중단되었다. CA SHA256 지문 비교로 보완한 재시도에서 설치 성공을 확인했다. PC2 CA 자체와 PC1 서버 인증서는 교체하지 않았다. CA 개인키는 다른 PC나 Git으로 옮기지 않는다.

서버 인증서 교체만으로 앱 DB 통신 전체가 TLS로 바뀌지는 않는다. 현재 require_secure_transport=0이며 앱 TLS 적용은 별도 검토한다. 역방향 복제에는 CA·서버 신원 검증과 클라이언트 인증서를 적용할 예정이다.

## 내일 진행 순서

1. Docker Desktop과 DB, pfSense·Ubuntu VM을 기동하고 고정 IP를 확인한다. PC1 k3s server와 PC2 k3s-agent가 정상인지 확인한다. PC1 DB는 1/1, PC2 DB는 0/0, API DB_HOST는 PC2여야 한다.
2. 공개 readiness와 Primary 예약 백업·감시 상태를 확인한다. PC2의 기존 PC1→PC2 채널 및 Replica용 예약 작업은 중지 상태로 유지한다.
3. PC2→PC1 복제 계정 `loop_repl_pc1`을 준비한다. REPLICATION SLAVE 권한과 접속 Host·클라이언트 인증서 조건을 제한한다. MySQL이 보는 실제 출발지 Host는 Docker NAT 때문에 Windows IP와 다를 수 있으므로 확인 후 지정한다.
4. PC1용 CA·클라이언트 인증서·클라이언트 키만 안전하게 전송한다. PC1 영속 데이터 볼륨 안의 전용 디렉터리에 mysql이 읽을 수 있도록 설치하고 지문·권한을 확인한다.
5. PC1 GTID가 PC2의 부분집합인지, 필요한 PC2 binlog가 보존되어 있는지 재확인한다. PC2 신규 쓰기가 있으므로 PC1을 임의로 쓰기 가능하게 바꾸거나 이전 채널을 재시작하지 않는다.
6. PC1에서 PC2를 Source로 하는 GTID 자동 위치·TLS 서버 검증·클라이언트 인증 복제를 설정한다. 앱 DB 필터의 재시작 후 유지 방식도 확인한다. PC1의 read_only/super_read_only는 계속 켜 둔다.
7. 역방향 IO/SQL 모두 Yes, 오류 0, GTID 따라잡기와 PC2 웹 신규 쓰기의 PC1 반영을 확인한다. 역방향 복제가 안정화되기 전에는 장애 전환 완료로 발표하지 않는다.
8. 실제 DB 대상과 방화벽 허용 출발지를 배포 문서·설정에 반영한다. n8n 담당자와 10443 CA·인증·실제 이벤트 연동 및 일반 PC 차단을 확인한다.
9. 이후 control plane·DNS 장애 대책과 PC1 전체 장애 시험 범위를 정한다. 자동 DB 승격·자동 원복과 PC3 pfSense 이중화는 별도 작업이다.

## 오늘 종료 시 유지할 사항

마지막 백업 성공까지 확인했다. 장비를 종료한다면 사용자·n8n 요청을 멈추고 VM과 DB 컨테이너를 정상 종료한 뒤 Windows를 종료한다. PC1은 읽기 전용, PC2는 Primary인 현재 영속 설정을 유지한다. 실제 장비 종료 수행 여부는 이 기록에서 확인하지 않았다. 내일 PC1을 원래 Primary로 자동 복귀시키지 않는다.

관련: [HAProxy 운영 전환 기록](2026-10-28-haproxy-public-cutover.md), [Primary 백업](../runbooks/mysql84-primary-backup.md), [역할별 예약·감시](../runbooks/mysql84-primary-schedule.md).
