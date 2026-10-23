# 보안 프로젝트 — 4인 통합 개발 확정 기준 v1.0

작성일: 2026-10-18 / 목적: A·인프라 담당·C·D의 개발 결과물을 동일 기준으로 통합한다.

> **2026-10-23 네트워크 기준 변경:** 학원망에서 프로젝트 전용 스위치·VLAN 분리 없이 Ubuntu VM 두 대의 k3s 웹/API와 Windows Docker MySQL을 사용한다. 현재 네트워크 정본은 [구성도](../../network/diagrams/academy-k3s-20261023.md), [주소](../../network/address-plan.md), [포트](../../network/port-matrix.md), [통신 경로](traffic-flow.md)다. 이 v1.0의 VLAN별 주소·VIP·NodePort·외부 Nginx·OpenVPN 대역·DB VIP 및 관련 4~6·9~11절의 네트워크 목표는 과거 설계 이력이며 실제 적용값이 아니다. 앱 DB의 현장 이름은 `my_new_board_db`다. 아래 과거 값을 근거로 장비·DB·환경변수를 변경하지 않는다.

이 문서는 사용자의 요청에 따라 결정한 새 개발 기준이다. 팀에 공유한 뒤 공통 기준으로 적용하며, 실제 저장소·장비에 이미 반영됐다는 의미는 아니다. 기존 8개 가이드에서 서로 다른 예시를 제시한 항목은 이 문서의 값으로 통일한다. 이후 변경은 변경 이유·영향 파일·검증 결과를 연결된 Issue/PR에 남긴다.

2026-10-19 실행 환경 추가 확인: 최초 공용 PC 실습은 Windows 11 + Docker Desktop 및 학원망을 사용한다. [두 PC Docker 실행 프로필](../operations/shared-pc-docker.md)에 따라 MySQL 복제부터 검증하며 아래 Ubuntu·VLAN·k3s·VIP 목표가 이미 구현되었다고 해석하지 않는다. 별도 Ubuntu VM을 먼저 설치하지 않으며 실제 웹 VIP·k3s 적용 방식은 후속 결정한다.

## 1. 역할과 변경 책임

| 담당 | 최종 책임 | 공동 개발·검증 |
|---|---|---|
| A | React·Flask, 인증·권한, DB 모델·Migration, API 계약 | C와 문의, 인프라 담당자와 결제·포인트 동시성, D와 인시던트 |
| 인프라 담당 | Docker·Compose, 이미지, k3s, Nginx·웹 VIP, MySQL 복제·백업·수동 전환 | A 실행 규격, C 네트워크, D 자원·장애 지표 |
| C | VLAN·IP·pfSense·VPN, Suricata, NetworkPolicy·보안 검증 | 인프라 담당 실제 경로, A 접근 권한, D 센서 이벤트 |
| D | Wazuh·Graylog·Zabbix, 이벤트 표준, n8n·Discord·재처리 | A 인시던트 API, 인프라 담당 운영 자원, C 탐지 로그 |

공통 라우터·인증 모듈·앱 초기화·ORM 모델 등록·패키지 및 잠금 파일은 A가 통합한다. 인프라 담당자가 앱 폴더에 추가하는 파일은 빌드용 `.dockerignore`로 한정한다. C/D는 담당 기능 모듈을 작성하고 공통 파일 변경 요구를 연결 PR로 A에게 전달한다. 같은 기능 파일의 동시 수정은 Issue에서 범위를 나눈 후 진행한다.

## 2. 구현 구조

- 프론트: React + Vite + TypeScript. API 호출은 상대 경로 `/api`만 사용한다.
- 백엔드: Python 3.12 + Flask Application Factory + SQLAlchemy. WSGI는 `backend/wsgi.py`의 `app`, 실행 포트는 5000이다.
- DB: MySQL 8.4 계열, InnoDB, utf8mb4. 앱 데이터와 보안 인시던트는 같은 `telecom` DB의 별도 테이블로 관리한다.
- 기반 OS: Ubuntu Server 24.04 LTS. 프론트 빌드 Node.js는 22 계열로 통일한다.
- 런타임의 정확한 패치·이미지 digest는 인프라 담당자가 최초 호환성 검증 후 `docs/contracts/versions.md`에 고정한다. A의 lock 파일과 함께 커밋하며, 버전 기록 없는 이미지는 통합하지 않는다. `latest`와 PC별 임의 업그레이드는 사용하지 않는다.
- 개인 개발 통합은 Compose, 공용 PC의 웹/API는 k3s로 실행한다. 공용 PC에 같은 앱을 Compose와 k3s로 이중 기동하지 않는다.
- 로그인까지 시험하는 로컬 Compose는 HTTPS `127.0.0.1:8443`을 사용한다. 로컬 hosts에서 `portal.telecom.test`를 127.0.0.1로 매핑하고 실습 CA를 신뢰한다. HTTP 8080은 HTTPS 8443으로 이동시킨다. 초기 HTTP Health 확인만으로 Secure 쿠키 인증을 검증했다고 판단하지 않는다.
- MySQL과 관제 도구는 호스트 또는 전용 Compose로 실행하고, 볼륨을 영속화한다. 관제·DB를 웹 Deployment의 replica 수로 복제하지 않는다.

## 3. 파일 위치

| 대상 | 정본 경로 |
|---|---|
| 프론트 / 백엔드 | `frontend/`, `backend/` |
| 프론트 / 백엔드 Dockerfile | `infrastructure/docker/frontend/Dockerfile`, `infrastructure/docker/backend/Dockerfile` |
| 빌드 컨텍스트 | 각각 `frontend/`, `backend/` |
| 로컬 통합 | `infrastructure/docker/compose/local/compose.yaml` |
| DB 모델 / Migration / Seed | `backend/app/models/`, `database/migrations/`, `database/seed/` |
| DB 복제 / 백업 / 복구 | `database/replication/`, `database/backup/`, `database/runbooks/` |
| k3s 워크로드 / 정책 | `infrastructure/kubernetes/base/`, `infrastructure/kubernetes/network-policies/` |
| 주소 / 포트 / 통신 흐름 | `network/address-plan.md`, `network/port-matrix.md`, `docs/contracts/traffic-flow.md` |
| 실행 / 환경변수 / API | `docs/contracts/runtime.md`, `environment-variables.md`, `api-common.md` 및 기능별 `*-api.md` |
| 이벤트 표준 | `docs/contracts/observability/event-schema.md` |
| k3s 통신·라벨 | `docs/contracts/k8s-network.md` |

`backend/migrations/`와 앱 폴더 안 Dockerfile은 별도 정본으로 만들지 않는다. Flask-Migrate의 Migration 디렉터리는 `database/migrations/`로 명시한다. API 컨테이너 일반 빌드 컨텍스트는 `backend/`이고 Migration은 저장소 루트에서 별도 작업으로 실행한다. 공용 PC Migration은 인프라 담당자가 루트 컨텍스트로 제작한 일회성 전용 이미지에서 수행하여 API 이미지에 없는 외부 경로를 참조하지 않게 한다.

## 4. 주소와 네트워크

| 구역 | 네트워크 | PC1 | PC2 | 특수 주소 |
|---|---|---|---|---|
| VLAN 10 DMZ | 192.168.10.0/24 | .11 | .12 | 웹 VIP 192.168.10.100 |
| VLAN 20 노드/WAS | 192.168.20.0/24 | .11 | .12 | k3s node-ip·overlay underlay |
| VLAN 30 DB | 192.168.30.0/24 | .11 | .12 | DB VIP 192.168.30.100 |
| VLAN 40 관제 | 192.168.40.0/24 | .11 | .12 | 이벤트 입력 PC2:8443 |
| VLAN 50 관리 | 192.168.50.0/24 | .11 | .12 | 관리자 SSH·UI |
| OpenVPN | 10.0.0.0/24 | 해당 없음 | 해당 없음 | 개인별 계정·인증서 |

각 VLAN 게이트웨이는 `192.168.<VLAN>.1`이다. 주소는 이 계획으로 통일하되 기존망과 충돌하면 장비에 적용하기 전에 C가 전체 주소 변경안을 하나의 변경으로 반영한다. 임의의 일부 주소만 바꾸지 않는다.

독립 pfSense + 802.1Q 관리형 스위치를 기준 구성으로 채택한다. 독립 장비가 없으면 PC2 pfSense VM 프로필을 사용하고 PC2 장애 시 WAN/VPN 중단을 명시한다. 두 프로필을 한 환경에서 혼용하지 않는다. 스위치·NIC 조건을 충족하지 못하면 물리 VLAN 실증은 진행하지 않고 로컬 검증 단계로 유지한다. 실제 NIC 이름·스위치 포트는 C의 장비 실사표에 대응시킨다.

모든 VLAN IP는 서비스 수신·관리 등 명시한 목적에만 사용한다. 기본 경로와 정책 라우팅은 C가 한 번에 관리한다. 호스트가 여러 VLAN에 연결되므로 동일 호스트·동일 L2 통신은 pfSense를 우회할 수 있다. 호스트 INPUT/FORWARD와 Pod 정책을 함께 검증하며, 단순 호스트 라우팅으로 VLAN 간 우회를 허용하지 않는다. k3s가 요구하는 포워딩은 예외로 명세한다. IPv4 단일 스택으로 구축하고 실습 인터페이스의 불필요한 IPv6 우회 접근을 차단한다.

## 5. 포트와 실제 요청 경로

| 통신 | 확정값·허용 범위 |
|---|---|
| 고객 웹 | 웹 VIP TCP 443, HTTP 80은 HTTPS 리다이렉트만 |
| Nginx → React | VLAN20 노드 IP:30080 → 컨테이너 80 |
| Nginx → Flask | VLAN20 노드 IP:30500 → 컨테이너 5000 |
| Flask → DB | 192.168.30.100:3306 |
| Replica → Primary 복제 | 192.168.30.12 → 192.168.30.11:3306, 역할 변경 후 역방향 |
| k3s 가입/API | PC2 → PC1 VLAN20 TCP 6443 |
| Flannel VXLAN | 양 노드 VLAN20 UDP 8472 |
| kubelet 관리 | 필요한 양 노드 VLAN20 TCP 10250만, 관리 주체 제한 |
| VRRP | VLAN10 양 호스트 IP protocol 112, TCP/UDP 포트 아님 |
| VPN | pfSense UDP 1194, 터널 이후 승인 관리 대상만 |
| SSH | VLAN50 TCP 22, VPN/승인 관리자만 |
| Wazuh Agent → Manager | VLAN40 TCP 1514, 등록 1515는 등록 시만 |
| 로그 → Graylog | PC1 VLAN40 GELF TCP 12201 |
| Zabbix 수집 | Active Agent → PC2 VLAN40 TCP 10051; Passive 10050은 기본 비활성 |
| 이벤트 수신 | PC2 VLAN40 HTTPS 8443, D의 승인된 송신기만 |
| n8n·relay·내부 API 프록시 | PC2 loopback 5678 / 18090 / 18081 |
| Discord | PC2 → Discord HTTPS 443 |

NodePort `30050`은 폐기하고 `30500`으로 통일한다. NodePort는 승인된 호스트 Nginx 경로만 접근하도록 제어한다. 프록시의 upstream 접속 출발지는 각 호스트의 VLAN20 주소로 고정한다. DNS·NTP·인증서·패키지 갱신에 필요한 송신은 목적지와 실행 주체를 C 통신표에 별도 기록한다. 복제 화살표의 데이터 흐름 Primary→Replica와 연결 시작 방향 Replica→Primary를 구분한다.

## 6. 공개·관리·자동화 경로

- 고객 주소: `https://portal.telecom.test` → 웹 VIP. 실습 CA 인증서를 사용하고 개발 PC에 신뢰를 설정한다. 실습 DNS는 pfSense Resolver에서 관리한다.
- 관리자 주소: `https://manage1.telecom.test`, `https://manage2.telecom.test` → 각 PC VLAN50 주소. VPN/승인 관리망에서만 접근한다. 한쪽 장애 시 다른 주소로 접속하고 필요하면 다시 로그인한다.
- 공개 Nginx는 `/admin`, `/admin/`, `/api/admin`, `/api/admin/`, `/api/internal`, `/api/internal/`를 일관되게 거부한다. 경로 정규화·하위 경로 우회도 시험한다.
- 관리 Nginx는 관리자 화면·인증·관리 API를 제공하되 `/api/internal/*`는 공개하지 않는다.
- 자동 티켓 API는 `POST /api/internal/incident-events`로 확정한다. n8n은 PC2 loopback의 `http://127.0.0.1:18081/api/internal/incident-events`를 사용한다. loopback 전용 Nginx가 양 API NodePort로 전달하고 A의 API가 전용 서비스 토큰을 검증한다.
- 수동 사고 생성·조회·수정은 `/api/admin/incidents/*`에서 처리한다. 자동 수신 토큰은 이 관리자 API에 접근할 수 없다.
- 호스트 Nginx가 TLS를 종료한다. 내부 HTTP는 명시적으로 허용한 격리 경로에서만 사용한다. DB 복제와 관제 도구의 인증·TLS 설정은 별도로 적용한다.
- Nginx는 외부가 보낸 추적·프록시 헤더를 그대로 신뢰하지 않고 `X-Request-ID`, `X-Forwarded-For`, `X-Forwarded-Proto`를 설정한다. Flask는 승인된 한 단계 프록시만 신뢰한다.
- Wazuh·Graylog·Zabbix·n8n UI는 관리 Nginx의 전용 경로 또는 관리망 전용 수신점으로 제공한다. 각 도구 native UI/API·Indexer·MongoDB는 WAN에 노출하지 않는다.

## 7. 인증·권한·API 공통 형식

- 인증은 MySQL `auth_sessions` 기반 서버 세션으로 확정한다. 브라우저에는 무작위 opaque token만 주고 DB에는 그 해시를 저장한다. API Pod 메모리를 세션 정본으로 사용하지 않는다.
- 쿠키 이름은 `__Host-telecom_session`, `Secure`, `HttpOnly`, `SameSite=Lax`, `Path=/`, Domain 미설정이다. 인증 검증은 양 Pod가 같은 DB를 사용한다.
- 세션 유휴 만료는 30분, 절대 만료는 8시간이다. 로그아웃 시 DB 세션을 폐기한다. 비밀번호 변경·권한 변경 시 해당 사용자 세션을 폐기한다.
- 상태 변경 요청은 세션에 연결한 CSRF 토큰과 `X-CSRF-Token`을 검증한다. 로그인·회원가입은 JSON 및 허용 Origin 검증을 적용한다. 자동화 토큰 API는 브라우저 쿠키 인증과 분리한다.
- 역할은 `CUSTOMER`, `SUPPORT_ADMIN`, `SECURITY_ADMIN`이다. 상담 관리자는 고객 문의, 보안 관리자는 인시던트 업무를 수행한다. 역할만으로 타 분야 관리자 권한을 자동 부여하지 않는다.
- SUPPORT_ADMIN의 업무 권한은 문의 조회·답변·상태 변경, 모의 결제 조회·환불, 멤버십 정책 관리다. 포인트 잔액을 직접 덮어쓰는 권한은 제공하지 않는다. SECURITY_ADMIN은 사고 생성·조회·배정·상태·대응 이력을 관리하며 고객 결제·멤버십 수정 권한이 없다. 관리 역할의 신규 발급은 개발/실습용 비공개 계정 프로비저닝으로만 수행하고 공개 회원가입에서 역할을 선택하게 하지 않는다.
- 사용자 소유권은 서버가 인증 사용자 기준으로 검사한다. 임의 `user_id`를 신뢰하지 않는다. 권한 없는 객체는 404, 인증 없음은 401, 역할 거부는 403으로 통일한다.
- 로그인 실패 제한은 계정별 15분 5회, IP별 15분 20회이며 초과 시 429와 `Retry-After`를 반환한다. 카운터는 공유 DB에서 원자적으로 관리한다. 존재하지 않는 계정도 응답 차이로 노출하지 않는다.
- 정상 응답은 `{"success":true,"data":{...},"request_id":"..."}`, 오류는 `{"success":false,"error":{"code":"...","message":"..."},"request_id":"..."}`다.
- 일반 생성은 201, 검증 실패는 422, 상태/멱등 키 충돌은 409, 의존성 장애는 503이다. 금액은 원 단위 정수, 시간은 UTC ISO 8601이며 화면에서 KST로 표시한다.
- 비밀번호·세션·토큰·쿠키·전체 결제 요청은 로그에 남기지 않는다. 세션·비밀번호 해시 알고리즘과 파라미터는 A의 보안 계약에 고정하고 C가 검증한다.
- 비밀번호 해시는 Argon2id, memory 64MiB·iterations 3·parallelism 1·무작위 salt 16바이트·출력 32바이트로 통일한다. 세션 원문은 암호학적 난수 32바이트 이상이며 DB 조회용 해시는 SHA-256으로 저장한다. 비밀번호에 단순 SHA-256을 적용하지 않는다.

공통 환경변수 이름은 아래 표로 고정한다. 실제 Secret은 로컬 파일 또는 보호된 Secret 주입으로만 전달한다.

| 변수 | 로컬 Compose | 공용 PC |
|---|---|---|
| APP_ENV | local | lab |
| DB_HOST | mysql | 192.168.30.100 |
| DB_PORT / DB_NAME | 3306 / telecom | 동일 |
| DB_USER / DB_PASSWORD | 로컬 앱 전용 계정 | 공용 앱 전용 계정 |
| LOG_LEVEL / LOG_FORMAT | INFO / json | 동일 |
| INCIDENT_API_BASE_URL | http://internal-proxy:18081 | http://127.0.0.1:18081 |
| EVENT_RELAY_BASE_URL | http://event-relay:18090 | http://127.0.0.1:18090 |
| N8N_WEBHOOK_URL | http://n8n:5678/webhook/incident-v1 | http://127.0.0.1:5678/webhook/incident-v1 |
| INCIDENT_API_TOKEN | 자동 티켓 전용 Secret | 자동 티켓 전용 Secret |
| EVENT_INGEST_TOKEN | 이벤트 입력 전용 Secret | 동일 용도 별도 값 |
| DISCORD_WEBHOOK_URL | 테스트 채널 Secret | 실습 채널 Secret |
| N8N_ENCRYPTION_KEY | 영속 저장·백업할 Secret | 동일 정책 |

`DATABASE_URL`과 분리형 DB 변수를 혼용하지 않는다. 토큰들은 서로 다른 값으로 발급한다. 비밀번호·토큰 변경 시 생산자와 소비자를 같은 변경 절차로 갱신한다.

## 8. DB·Migration·거래 규칙

- 고객 문의는 `support_tickets`/`support_replies`, 보안 사고는 `security_incidents`/`incident_histories`로 분리한다.
- 사고 상태는 `OPEN → INVESTIGATING → RESOLVED → CLOSED`다. `RESOLVED → INVESTIGATING` 재개를 허용하고 변경 이력을 남긴다. 별도 `RESPONDING` 상태를 추가하지 않는다.
- 문의 상태는 `OPEN`, `IN_PROGRESS`, `ANSWERED`, `CLOSED`다.
- Migration 파일·순서는 A가 관리한다. 앱 시작 명령에서 자동 실행하지 않는다. 인프라 담당자가 배포 전 단일 일회성 작업으로 Primary에 실행하고, 복제 적용과 버전을 확인한 후 앱을 배포한다.
- 앱 계정에는 DDL·복제·승격 권한을 주지 않는다. 앱·Migration·복제·백업·관제 계정을 분리한다.
- 결제·포인트는 서버의 원본 금액·혜택 비용을 기준으로 처리한다. 행 잠금 또는 원자적 조건 갱신과 DB 제약을 사용한다.
- 결제와 혜택 사용 요청에는 `Idempotency-Key`를 사용한다. 사용자+작업+키를 고유하게 저장하고 요청 본문 해시도 비교한다. 같은 내용 재요청은 기존 결과, 같은 키에 다른 내용은 409다.
- 동일 청구서의 중복 성공과 중복 포인트 반영은 서로 다른 요청 키에도 차단한다. 결제 청구서 잠금·상태 검사와 포인트 원장의 업무 식별자 고유 제약으로 검증한다.
- 결제는 Mock으로 구현한다. 실제 PG 연동은 이번 기준의 필수 범위에서 제외한다. 개인정보·실제 카드정보는 사용하지 않는다.
- 파일 업로드는 초기 범위에서 제외한다. Pod 로컬 파일에 의존하는 고객 기능을 추가하지 않는다.

## 9. 웹 이중화와 Kubernetes

- PC1은 k3s Server+Worker, PC2는 Agent다. Namespace는 `telecom`, 앱 라벨은 `app=telecom-web`, `app=telecom-api`다.
- Pod CIDR은 `10.42.0.0/16`, Service CIDR은 `10.43.0.0/16`이다. VPN/VLAN과 중복되면 구축 전 전체 주소 계약을 변경한다.
- Flannel VXLAN과 k3s 기본 NetworkPolicy 컨트롤러를 사용한다. Traefik과 ServiceLB는 비활성화하여 호스트 Nginx의 80/443과 충돌하지 않게 한다.
- React와 API를 각각 별도 Deployment로 배포하고 각 replicas=2, hostname 기준 required anti-affinity를 사용한다. 한 노드 장애 시 실행본 1개가 남는 것이 정상이며 두 개 유지 보장을 하지 않는다.
- 업데이트는 `RollingUpdate`, `maxSurge: 0`, `maxUnavailable: 1`로 설정한다. 두 노드에 required anti-affinity를 적용한 상태에서 세 번째 Pod 자리를 기다리며 배포가 멈추지 않게 한다. 두 노드·두 실행본이 정상일 때만 일반 롤링 배포를 시작한다.
- NodePort는 `externalTrafficPolicy: Local`을 사용한다. 외부 Nginx가 두 노드 upstream을 분산하고 장애 노드를 제외한다. 해당 노드에 로컬 정상 Pod가 없으면 그 upstream은 실패하므로 두 노드 배치와 Nginx 제외 동작을 함께 시험한다.
- Web/API liveness는 프로세스 상태, readiness는 서비스 준비 상태로 구분한다. DB 장애 때문에 liveness가 실패해 반복 재시작하지 않게 한다.
- 웹 VIP는 VLAN10에서 Keepalived로 자동 전환한다. 감시는 로컬 Nginx 진입점 기준이며 공통 DB 장애를 VIP 이동 조건으로 사용하지 않는다. DB·upstream 장애는 별도 지표로 관제한다.
- 비멱등 POST를 프록시가 임의 재전송하지 않도록 설정한다. 앱 재요청은 API의 멱등성 계약으로 처리한다.
- PC1 전체 장애 시 제어부·DB·Graylog가 중단될 수 있다. 남은 Pod의 지속 실행·DNS·라우팅을 실측하며 전체 자동 복구를 합격 기준으로 삼지 않는다.

## 10. NetworkPolicy와 관리 접근

- `telecom` Namespace는 ingress/egress 기본 차단이다. 허용 정책·롤백·정상 기준을 준비한 뒤 적용한다.
- Web/API ingress는 호스트 Nginx의 실제 VLAN20 출발지·노드 경로에 맞춘다. `telecom-web` Pod만 허용하는 API 정책을 사용하지 않는다.
- API egress는 DB VIP `192.168.30.100/32:3306`, CoreDNS UDP/TCP 53 등 계약에 명시한 필수 경로만 허용한다. Web Pod의 불필요한 외부 통신은 차단한다.
- 같은 노드에서 발생한 트래픽과 NodePort NAT는 NetworkPolicy만으로 완전 통제되지 않을 수 있으므로 호스트 방화벽·직접 접근 차단 결과까지 함께 제출한다. YAML 존재만으로 통과 처리하지 않는다.
- VPN은 VLAN50 승인 SSH/UI만 허용하고 VLAN30 직접 접속은 차단한다. 긴급 DB 작업은 승인된 SSH 접속 후 호스트 내부 작업으로 수행한다.
- 모니터링·자동화는 승인된 시스템 통신 예외로 명시한다. 관리망 정책을 사용자 VPN 규칙과 시스템 서비스 규칙으로 구분한다.
- Suricata는 IDS 모드로 고정한다. 센서가 실제 보는 구간과 SID를 기록하고 HTTPS 본문·호스트 내부·overlay 전체 탐지를 주장하지 않는다. IPS 변경은 별도 범위 변경으로 다룬다.

## 11. MySQL 수동 전환과 백업

- 앱 설정은 `DB_HOST=192.168.30.100`, `DB_PORT=3306`, `DB_NAME=telecom`이다. `db-primary`는 문서상의 역할 이름으로만 사용하고 DNS 전환에 의존하지 않는다.
- 웹 VIP `.10.100`은 자동, DB VIP `.30.100`은 인프라 담당자가 수동으로 이동한다. DB VIP에 Keepalived 자동 승격을 연결하지 않는다.
- 정상 상태는 PC1 Primary+DB VIP, PC2 Replica이며 Replica는 `read_only`와 `super_read_only`다. GTID 기반 비동기 복제를 사용한다.
- 수동 전환 순서는 쓰기 중단 → 구 Primary 쓰기 차단/격리 확인 → 복제 상태·데이터 손실 평가 → Replica 승격 → DB VIP 이동·ARP 갱신 → 앱 연결 회복 → 거래 검증이다. 구 Primary 격리를 증명하지 못하면 승격하지 않는다.
- DB 수신 설정은 VIP 소유 상태와 함께 동작하도록 구성하고, 호스트 방화벽에서 VLAN30의 명시한 출발지·포트만 허용한다. VIP가 없는 Replica가 수신 주소 바인딩 오류로 시작하지 못하는 구성을 사용하지 않는다.
- 앱은 DB 풀의 죽은 연결을 제거하고 재연결한다. 커밋 결과가 불명확한 결제·포인트·티켓 쓰기는 같은 멱등 키로 확인하며 자동 재실행으로 중복 처리하지 않는다.
- PC1 제어부가 중단돼도 인프라 담당자는 VLAN50 SSH/콘솔로 DB VIP를 이동한다. DB 주소 변경을 위한 Kubernetes 재배포는 필요하지 않다. 기존 Pod가 없거나 동작하지 않으면 제어부 복구를 먼저 수행한다.
- PC1 복귀 시 쓰기를 막고 새 Primary를 기준으로 Replica로 재구성한다. 원래 Primary로 자동 복귀시키지 않는다.
- DB 백업은 매일 02:00 KST, 최근 일별 7개+주별 4개를 암호화 보관한다. 두 PC와 분리된 매체에 사본을 둔다. 저장 공간 부족 시 조용히 삭제하지 않고 경고한다.
- 매주 및 시연 전 별도 DB로 복원하고 거래·제약·건수를 확인한다. 앱 DB 외 관제 설정·n8n 데이터 및 암호화 키·k3s 복구 자료도 보호된 별도 백업에 포함한다.
- 시험 목표는 웹 진입점 30초 이내, DB 수동 전환 15분 이내다. 계획 전환은 GTID 적용 확인 후 미반영 거래 0건, 돌발 장애는 실제 손실량을 보고한다. 목표 달성 전 무중단·무손실 보장으로 표현하지 않는다.

## 12. 이벤트 표준과 자동 티켓 API

필수 이벤트 형식:

```json
{
  "schema_version": "1.0",
  "source": "suricata",
  "event_id": "sensor-c-01:lab-0001",
  "event_type": "ids.suricata.alert",
  "detected_at": "2026-10-18T04:00:00Z",
  "severity": "medium",
  "title": "실습 IDS 탐지",
  "asset": {"host": "pc1", "service": "telecom-api"},
  "scenario_id": "IDS-01",
  "request_id": "req-lab-0001",
  "evidence": {"signature_id": 1000001}
}
```

- `schema_version`, `source`, `event_id`, `event_type`, `detected_at`, `severity`, `title`, `asset`는 필수다. `received_at`은 수신기가 추가하며 `scenario_id`, `request_id`, `evidence`는 해당할 때 사용한다.
- severity는 `info/low/medium/high/critical`이다. `error`는 앱 로그 수준으로만 사용한다. 도구별 숫자 severity 변환은 D의 매핑표 한 곳에서 관리한다.
- 최초 severity 매핑은 Wazuh 0~3=info, 4~6=low, 7~9=medium, 10~12=high, 13~15=critical이다. Suricata 1=high, 2=medium, 3=low이며 그 외 값은 info로 두고 원본을 보존한다. Zabbix 0=info, 1=low, 2=medium, 3~4=high, 5=critical로 매핑한다.
- 이벤트명은 `auth.login.failed`, `auth.rate_limited`, `auth.access.denied`, `auth.object_access.denied`, `ids.suricata.alert`, `payment.validation.failed`, `payment.duplicate_request`, `membership.redeem.denied`, `http.error.rate_high`, `infra.mysql.replication_stopped`, `infra.web.vip_changed`, `infra.backup.failed`로 통일한다.
- 원본의 `timestamp`는 정규화 과정에서 `detected_at`으로 매핑한다. Wazuh/Graylog를 통과해도 원본 source/event_id를 바꾸지 않는다. 수집기 이름은 별도 `collector` 필드에 둔다.
- 동일 원본의 경로별 중복은 `(source,event_id)`로 제거한다. 서로 다른 실제 이벤트를 하나의 사건으로 묶는 상관 분석은 별도 기능으로 관리한다.
- 내용 해시는 정규화한 원본 필드만으로 계산하고 수집 단계의 `received_at`, `collector`, 재시도 횟수는 제외한다. 동일 원본이 두 수집 경로로 들어와도 수집 메타데이터 차이 때문에 409가 발생하지 않게 한다.
- API는 이벤트 해시와 `(source,event_id)` 고유 제약을 저장한다. 최초는 201+incident_id, 같은 내용 재전송은 200+동일 incident_id+deduplicated=true, 같은 키에 다른 내용은 409다.
- 422는 입력 수정, 401/403은 인증 수정 대상으로 자동 반복하지 않는다. 429는 Retry-After를 따르고, 5xx/timeout은 같은 키로 제한 재시도한다. 성공 여부 불명 상태를 실패 확정으로 덮어쓰지 않는다.

## 13. 이벤트 보존·n8n·Discord

- D는 PC2에 작은 이벤트 수신·재처리 서비스와 전용 SQLite WAL 저장소를 둔다. 이는 n8n 내부 DB와 별도다. 이벤트는 `https://events.telecom.test:8443/events`로 수신하며 토큰·출발지·크기·스키마를 검증한다.
- 이 서비스는 디스크 저장을 커밋한 후에만 202를 반환한다. 저장 불가 시 503을 반환하고 송신기는 로컬 파일 대기에 보존한다. 동일 키·동일 내용은 기존 inbox_id를 반환하고, 내용 충돌은 409다.
- SQLite는 `synchronous=FULL`과 트랜잭션을 사용하고 HTTP 전달 중에는 DB 쓰기 잠금을 유지하지 않는다. 실행 중 백업은 SQLite backup API 또는 서비스를 멈춘 일관된 사본으로 수행하며 `.db` 파일 하나만 복사하지 않는다.
- 수신 서비스는 loopback의 활성 n8n Production Webhook으로 처리 요청을 전달한다. 상태와 임대 만료 시각을 저장하고 n8n 재시작·응답 유실 시 동일 이벤트를 다시 처리한다.
- n8n은 API 티켓 결과 확인 → Discord 전송 순서로 처리한다. 티켓 성공 뒤 알림만 실패하면 기존 incident_id를 유지하고 알림만 재시도한다.
- 재시도는 초기 요청 외 최대 5회, 대기 10/30/60/120/300초다. 429는 Retry-After 이상 대기한다. 한도 초과는 수동 재처리 목록으로 이동하고 자동 삭제하지 않는다.
- 상태는 `PENDING`, `PROCESSING`, `TICKET_UNKNOWN`, `TICKET_CREATED`, `NOTIFY_PENDING`, `DONE`, `NEEDS_REVIEW`로 관리한다. 재처리 데이터는 처리 결과·시도 횟수·오류·incident_id를 보존한다.
- n8n은 단일 인스턴스+영속 SQLite로 실행한다. Queue mode·Redis·MySQL 연동은 사용하지 않는다. `N8N_ENCRYPTION_KEY`와 데이터 볼륨을 함께 보호·백업한다. 수신 저장소와 n8n 저장소는 파일·볼륨을 공유하지 않는다.
- 공용 Ubuntu의 n8n 컨테이너는 host 네트워크와 `N8N_LISTEN_ADDRESS=127.0.0.1`을 함께 사용한다. 수신·재처리 서비스는 PC2 호스트 서비스로 실행한다. 로컬 Compose에서는 같은 bridge 네트워크의 `n8n`, `event-relay`, `internal-proxy` 서비스 이름을 사용한다. bridge 컨테이너의 127.0.0.1을 호스트 주소로 오해하지 않도록 환경별 URL을 위 표로 고정한다.
- Discord는 최소 식별 정보와 incident_id만 전송하고 `wait=true` 응답의 메시지 ID를 보존한다. 외부 전송 성공 직후 응답 유실·프로세스 장애에서는 알림 중복 가능성이 남으므로 정확히 한 번 전송을 보장하지 않는다. 티켓은 DB 멱등성으로 중복을 막는다.
- `DONE` 데이터는 30일 보관 후 정리하고 미해결·상태 불명 데이터는 검토 없이 삭제하지 않는다. PC2 전체 장애·디스크 손실까지 이 저장소가 해결하는 것으로 표현하지 않는다.

## 14. 관제·자원·공개 저장소

- PC1에는 Graylog+MongoDB+호환 검색 백엔드, PC2에는 Wazuh 전체+Zabbix+전용 DB+n8n+이벤트 수신 서비스를 배치한다. 양 호스트에 Wazuh/Zabbix Agent를 둔다.
- Zabbix DB는 앱의 복제 DB와 별도 인스턴스다. Wazuh Indexer와 Graylog 검색 백엔드도 공유하지 않는다. 관제 이미지의 호환 조합은 D가 검증하고 인프라 담당자의 버전 잠금 문서에 함께 기록한다.
- PC1에서 PC2의 관제 진입점을 확인하는 경량 외부 점검을 실행하고 PC1 로컬에 기록한다. PC2 장애 때 PC2 n8n을 경유한 알림을 기대하지 않는다. 외부 점검기는 별도 보호 자격증명으로 운영 알림만 전송한다.
- 공용 PC의 전체 구성 검증 기준은 각 RAM 32GB 이상·SSD·8개 논리 CPU 이상이며, 이는 용량 계획의 출발점이다. 실제 메모리·IO·로그 증가량을 측정한다. 부족하면 서비스 동시 구동을 중단하고 축소 검증 상태로 표시한다.
- 최초 통합은 한 도구씩 기동하고 로그 보존은 기본 7일로 시작한다. RAM 85%가 5분 지속되거나 여유 디스크 20% 미만이면 부하 시험을 중단한다.
- `.env`, 인증서 개인키, VPN 프로필, kubeconfig, k3s 토큰, Discord URL, DB 덤프·생 로그는 Public GitHub와 Notion에 올리지 않는다. 저장소에는 템플릿·합성 이벤트·비식별 증거만 둔다.

## 15. GitHub와 공동 통합 순서

- main은 안정 버전, develop은 통합 브랜치다. 작업 브랜치는 목적별 `feature/*`, `infra/*`, `security/*`, `monitor/*`, `fix/*`, `test/*`, `docs/*`를 사용하며 별도 도구명 접두사는 붙이지 않는다. 인프라 작업은 `infra/*`를 사용한다.
- 커밋은 사용자 계정, 한글 `<type>(<scope>) : <요약>` 형식이며 feat/fix/build/chore/ci/docs/style/refactor/test/perf 타입을 사용한다. 예: `fix(network) : API NodePort를 30500으로 통일`.
- 한 기능 또는 독립 변경씩 커밋·PR을 나눈다. main/develop 직접 push를 사용하지 않는다. 로컬 검증 후 작업 브랜치를 push하고 영향 담당자가 검토한 PR을 develop에 통합한다. CODEOWNERS는 추가하지 않는다.
- API·환경변수·포트·라벨·로그 필드 변경은 코드+계약+샘플+관련 테스트를 같은 PR 또는 연결 PR로 갱신한다.

통합 순서:

1. A 최소 React/Flask·live/ready → 인프라 담당 이미지·Compose → DB 읽기/쓰기·재기동 후 보존.
2. A 공유 세션·역할·소유권 → C 고객 간 차단 → 두 API 실행본 교차 인증.
3. D 표준 이벤트 → 수신 저장 → Mock API → n8n → 실제 인시던트 API·관리자 화면.
4. 인프라 담당 k3s·라벨·노드 분산 → C 허용/차단 정책·DNS·DB·관리 접근.
5. 결제·포인트 동시성, 이벤트 중복·timeout, Discord 실패, 프로세스 재시작 후 재처리.
6. 웹 VIP·DB 복제·별도 복원·수동 승격·PC1/PC2 전체 장애·제한 부하를 각각 시험.

## 16. 통합 완료 기준

- [ ] 새 PC에서 잠금 버전·문서 명령으로 이미지 빌드 및 로컬 통합 재현
- [ ] 공개 웹·관리 UI·내부 API의 접근 경계 확인
- [ ] 두 API 실행본에서 동일 세션·권한·요청 제한 동작
- [ ] Migration 1회 실행·Replica 적용 확인
- [ ] 금액·포인트·동시 요청·서로 다른 키의 중복 거래 방지
- [ ] 실제 Nginx/NodePort 경로, DNS·DB 허용과 비인가 경로 차단 확인
- [ ] 동일 이벤트 반복·동시 요청에도 티켓 1개, 다른 내용 충돌은 409
- [ ] API 장애·Discord 장애·n8n/수신기 재시작 뒤 상태·재처리 확인
- [ ] 독립 백업의 실제 복원과 DB VIP 수동 전환·안전한 복귀 확인
- [ ] PC1/PC2 전체 장애에서 남는 기능과 중단 기능을 증거로 기록
- [ ] Commit·버전·테스트 ID·request_id/event_id/incident_id·결과 연결
- [ ] 설계/로컬 검증/공용 PC 실증 상태를 구분하고 미실행을 성공으로 기록하지 않음

## 기술 근거

- [K3s 기본 네트워크 서비스·Traefik·ServiceLB](https://docs.k3s.io/networking/networking-services)
- [Kubernetes NodePort의 source IP·Local 정책](https://kubernetes.io/docs/tutorials/services/source-ip/)
- [Kubernetes NetworkPolicy의 시행 조건과 노드 통신 예외](https://kubernetes.io/docs/concepts/services-networking/network-policies/)
- [MySQL 복제 연결·수신 스레드](https://dev.mysql.com/doc/refman/8.4/en/replication-threads.html)
- [n8n DB 설정 공식 소스](https://github.com/n8n-io/n8n-docs/blob/main/docs/deploy/host-n8n/configure-n8n/basic-configuration/use-environment-variables/database.md)

주소·서비스 배치·인증·API·재처리·시험 목표는 이 프로젝트를 위한 설계 결정이다. 제품의 보장이나 실장비 검증 결과를 의미하지 않는다.
