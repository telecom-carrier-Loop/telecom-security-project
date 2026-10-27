# 2026-10-27 DB 보안 보완 및 파트별 인계

공유 이슈: [#40](https://github.com/telecom-carrier-Loop/telecom-security-project/issues/40). 코드·절차 PR: [#39](https://github.com/telecom-carrier-Loop/telecom-security-project/pull/39). 기준: Asia/Seoul. 현장 실행은 사용자가 수행했으며 작성 환경에서 서버에 직접 적용하지 않았다.

## 현재 상태

| 항목 | 확인 내용 |
|---|---|
| 앱 DB 계정 | 두 k3s API의 CURRENT_USER가 webuser@172.17.0.1, DB my_new_board_db, 두 Pod 1/1 화면 확인 |
| 앱 전환 | API 전용 Secret 참조로 계정 변경. root·복제·백업 계정 삭제 없이 진행 |
| 공개 HTTPS | PC1 Windows CA 등록 후 .3.30 readiness 200 / database ok 화면 확인 |
| PC1 방화벽 | 최초 Apply 실패 후 수정본으로 복구·재시도. 사용자가 연결·HTTPS 시험까지 정상이라고 보고. Status·각 TCP 결과는 후속 기록에 보관 |
| PC2 방화벽 | 적용 안내 단계. 적용 완료 보고는 아직 없음 |
| 변경 후 회귀 | 두 API 새 DB 연결·Replica·새 백업·관제 전체 회귀는 추가 확인 필요 |
| 공개 관리자 | .3.30 공통 주소의 관리자 경로 차단 해제 완료 보고는 없음. 기존 PC3 9443 관리자 접근 정상 기록과 구분 |

현재 결과가 앱→DB TLS·전체 방화벽 프로필·모든 Docker 서비스 접근 제한 완료를 의미하지 않는다. 일반 학원 PC를 프로젝트 외부 사용자로 정의하지만 인터넷 공개나 VLAN 격리 상태는 아니다.

## 수행한 작업

1. 중단된 Primary MySQL 시작과 Replica IO 수신 재개, 예약 백업·Discord 감시 재개를 기록했다.
2. 두 API의 root@% 접속과 비암호화 session을 확인하고 webuser를 생성해 업무 DB CRUD 권한으로 전환했다.
3. 새 webuser 접속 시험 1045는 계정·암호 확인 후 해결됐고 두 Pod의 실제 운영 계정 전환과 rollout 완료를 확인했다.
4. PC1 Windows의 UNTRUSTED_ROOT는 프로젝트 CA 신뢰 등록으로 해결했다. DB 계정 전환 오류와 구분했다.
5. 두 Windows 보고서에서 Public 프로필 비활성 및 Docker TCP Any 허용을 확인했다. API·복제 출발지와 Docker 게시 관제 서비스를 식별했다.
6. Plan/Apply/Status/Rollback 도구를 추가했다. 첫 현장 적용에서 발견된 ::1 원본 거부와 GpoBoolean 복구 바인딩 오류를 ec7cbcb에서 수정했다. 중단된 기존 state 복구와 새 디렉터리 재시도 시험을 추가했다.
7. PC1에서 수정본 재시도 후 연결·HTTPS 시험 성공 보고를 받았다. PC2에는 PC1 회귀 확인 후 순차 적용한다.

## 다른 파트의 확인 항목

| 담당 | 확인할 것 |
|---|---|
| 웹 | 고객·관리자 조회와 시험 데이터 쓰기, 세션·CSRF 유지. webuser에는 DDL 권한이 없으므로 migration은 별도 운영 계정. 공통 주소 관리자 전환 시 익명 401 / CUSTOMER 403 / ADMIN 200 확인 |
| 관제 | PC1 Graylog에 새 이벤트 도착, 양쪽 Wazuh Agent 최근 접속, PC2 Zabbix 최신 지표, n8n→Discord 실제 이벤트 전달 |
| 네트워크/pfSense | .3.30:443→.7.185:30443 유지. 사용자용 DB 3306 NAT를 추가하지 않음. 기존 9443 제한 유지 및 다른 사용자 PC의 DB 직접 접근 실패 확인 |
| DB·k3s | PC2 적용, 두 노드 Ready, 두 API 새 DB 연결, Replica IO/SQL Yes·오류/지연 확인, 실제 새 백업 PASS, PC별 state.json/before.wfw 경로 보관 |

PC1 Graylog UDP 1514/5140/12201은 학원 .3.0/24·.7.0/24에서 허용 준비한다. Wazuh TCP 1514/1515, n8n 5678, PC2 Zabbix 서버 10051·웹 8081 등 다른 Docker TCP 포트는 기존 허용 범위를 유지한다. 실제 listener가 있는 네이티브 Zabbix Agent 10050은 서버 PC1·PC2 원본을 허용한다. 오래된 대시보드 화면이 뜨는 것만으로 새 로그·지표 수집 성공을 판단하지 않는다.

## PC2 진행 순서

상세 명령은 [방화벽 실행 문서](../runbooks/mysql-firewall-scope.md)에 있다.

1. PC1의 새 API 연결과 관제 회귀가 정상인지 확인한다.
2. PC2 관리자 PowerShell에서 수정 커밋 ec7cbcb 이상의 도구를 받는다. git pull 대신 git fetch/show로 도구만 가져올 수 있다.
3. PC2 전용 새 StateDirectory를 정하고 Role PC2의 Plan→Apply→Status를 각각 성공 확인 후 진행한다. Apply를 반복하거나 기존 state를 지우지 않는다.
4. Public True 확인. 별도 사용자 PC→.3.19:3306 False, .3.30 HTTPS readiness 200을 확인한다. PC2→.3.18:3306은 True여야 한다.
5. PC1 Ubuntu에서 두 노드 Ready, 두 API 1/1과 새 DB 연결을 확인한다.
6. PC2의 SHOW REPLICA STATUS에서 IO/SQL Yes, 지연·오류 확인 후 실제 새 백업 Test를 실행한다.
7. 각 관제 담당자가 새 이벤트와 지표·Discord 전달을 확인해 이슈 #40에 결과를 기록한다.
8. 실패하면 해당 PC와 정확한 StateDirectory로 Rollback한다. 복구는 이전 Public 비활성 상태로 돌아갈 수 있으므로 이후 원인을 해결해 정책을 다시 적용한다.

## 남은 보완

- PC2 차단 정책과 PC1·PC2 변경 후 전체 회귀 증거.
- 앱→DB TLS: 마지막 검사에서 Ssl_cipher가 빈 값이었다. webuser 분리는 암호화를 추가하지 않는다.
- 별도 Docker telecom-api:5000의 실제 사용·계정·노출 점검. k3s의 계정 전환은 별도 Docker API를 변경하지 않는다.
- 다른 Docker TCP·관리 UI 노출 최소화, Private 프로필, 재부팅 후 정책·주소 유지.
- 공개 주소 관리자 역할 기반 접근 전환과 원본 IP 합쳐짐에 따른 로그인 제한·차단 영향 검증.
- 최신 백업 격리 복원, 미래 DB 장애 전환 시 webuser 준비.

다른 파트는 #40에 PC·확인 시각·시험 항목·성공/실패·비밀값 없는 오류를 남긴다. 비밀번호·Secret data·웹훅·세션 쿠키·CA 개인키는 공유하지 않는다. 관련 #36·#33은 이 문서 변경만으로 종료하지 않는다.
