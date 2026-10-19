# B 인프라와 A·C·D 연동 계약

기준 문서: [통합 확정 기준](../contracts/integration-baseline-v1.0.md). 아래는 현재 구현과 연결할 작업입니다.

## A에게 전달

> B의 Dockerfile·로컬 Compose를 준비했습니다. frontend/package.json 및 package-lock.json, backend/requirements.txt 및 wsgi.py를 추가해 주세요. 프론트는 npm ci / npm run build로 dist를 만들고, 백엔드는 gunicorn wsgi:app로 5000 포트에서 실행해야 합니다. requirements에 Gunicorn과 Flask-Migrate를 포함하고 database/migrations를 정본으로 초기화해 주세요. live는 DB와 무관한 생존 확인, ready는 DB 연결이 필요합니다. Migration은 별도 1회 실행하므로 앱 부팅 시 실행하지 마세요.

추가 연동 확인:

- DB 환경변수는 `.env.example`의 개별 DB_HOST/PORT/NAME/USER/PASSWORD를 사용합니다.
- 파일 기반 세션·프로세스 메모리 세션을 사용하지 않습니다. MySQL 공유 세션과 공통 서명키가 필요합니다. 필요한 키를 환경변수 계약에 추가하면 B가 Secret과 Compose 전달을 연결합니다. 현재 앱용 서명키는 미확정이며 임의로 생성해 계약에 넣지 않았습니다.
- 컨테이너 API는 UID 10001, 읽기 전용 루트이며 `/tmp`만 임시 쓰기가 가능합니다. 업로드·내보내기 저장소가 필요하면 별도 계약을 먼저 정합니다.
- 외부 `/api/admin`, `/api/internal`, `/admin`은 Nginx에서 차단합니다. 관리망은 C의 통신 제한과 A의 인증·권한 검사가 모두 필요합니다.
- 내부 이벤트 토큰은 앱 구현 시 별도 Secret으로 전달해야 합니다. 현재 Compose/k3s는 DB 접속 기반만 연결했고 이벤트·세션 Secret 연결은 A 구현과 함께 후속 작업합니다.
- 앱 이미지 빌드, 로그인·로그아웃·CSRF·Pod 간 공유 세션·장애 중 재시도 시험은 A 코드 통합 후 수행합니다.

## C에게 전달

> PC1·PC2는 준비되었지만 사양·NIC·스위치 모델은 미확인입니다. 스위치 802.1Q/트렁크·SPAN 지원, pfSense VM 위치와 가상 NIC, VLAN별 게이트웨이와 실제 인터페이스를 먼저 확인해 주세요. k3s의 VLAN20 노드 주소는 .11/.12이고 기본 Flannel VXLAN을 사용합니다. 웹 VIP 192.168.10.100은 자동, DB VIP 192.168.30.100은 수동입니다. B 템플릿 적용 전에 포트표와 NetworkPolicy를 함께 검증해야 합니다.

- [포트표](../../network/port-matrix.md)·[k3s 네트워크](../contracts/k8s-network.md)를 정본으로 확인합니다. VRRP IP protocol 112는 TCP/UDP 포트가 아닙니다.
- Nginx→NodePort는 VLAN20의 호스트 IP를 source bind합니다. API→외부 MySQL의 실제 출발지 IP/SNAT를 측정한 뒤 DB 계정 호스트 제한과 방화벽을 정합니다.
- 관리 VLAN50/VPN을 제외한 NodePort·DB·대시보드 직접 접근을 막습니다. Service의 externalTrafficPolicy=Local과 양쪽 노드 Pod 배치를 함께 확인합니다.
- NetworkPolicy는 C 담당입니다. 현재 B PR에 정책을 임의로 추가하지 않았습니다.

## D에게 전달

> B는 공용 PC Nginx에 127.0.0.1:18081 → 정확히 /api/internal/incident-events 경로만 허용하는 프록시 템플릿을 준비했습니다. 호스트 네트워크 기반 event-relay에서 연결하는 계약입니다. 이벤트 API 토큰 검증·원본 이벤트 중복 방지는 A/D 구현 후 함께 시험해야 합니다. Wazuh·Graylog·Zabbix·n8n·대시보드 프록시는 아직 포함하지 않았습니다.

- backup.sh는 성공 시 `infra.backup.succeeded` 형식의 로컬 JSON 한 줄을 출력합니다. 표준 이벤트 전체 envelope가 아니므로 D의 수집기에서 source/event_id/UTC timestamp를 붙여 정규화해야 합니다. 실패 이벤트 전달은 후속 구현 사항입니다.
- 비밀 없는 이벤트 예시와 실패·재시도·중복 시험을 먼저 준비합니다. 원본 로그·키·Discord webhook을 저장소에 올리지 않습니다.
- [백업 보존 기준](../../database/backup/retention.md)의 외부 저장소 및 복원 결과를 관제 알림과 연결합니다.

## 통합 완료 조건

앱 이미지 빌드 → Migration 1회 → 양쪽 노드 Ready → MySQL 세션 공유 → VLAN 접근 통제 → 웹 VIP 이동 → 수동 DB 복구 → 외부 암호화 백업 복원 → 이벤트·티켓 중복 방지·알림까지 실제 증거를 남겨야 완료입니다. 단일 k3s control plane 및 pfSense VM의 호스트 장애 한계는 남습니다.
