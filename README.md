# Telecom carrier Loop — 통신사 보안 프로젝트

React·Flask·MySQL 고객 포털에 네트워크 접근 통제, 보안 관제, 인시던트 자동화와 장애 복구 실습을 연결하는 4인 Monorepo입니다.

## 현재 상태

2026-10-23 기준, 학원망에서 PC1·PC2 Ubuntu VM의 k3s에 React/Nginx·Flask를 배포하고 SSH 포트 전달로 웹 접속을 확인했습니다. MySQL Primary·Replica와 예약 백업은 Windows Docker Desktop에서 실행합니다. 프로젝트 전용 스위치와 VLAN 분리는 사용하지 않습니다. pfSense·VPN·외부 HTTPS·웹 진입점 이중화는 후속 구성입니다.

**현재 네트워크 정본:** [학원망·VM k3s 구성도](network/diagrams/academy-k3s-20261023.md) · [주소](network/address-plan.md) · [포트](network/port-matrix.md) · [분석 근거](docs/architecture/academy-network-20261023.md).

인프라 담당자는 [개발·실습 시작 가이드](docs/operations/infra-start-here.md)와 [검증 기록](docs/operations/infra-verification.md)부터 확인합니다.

웹/API는 각 Ubuntu VM의 k3s에서, DB는 Windows Docker Desktop에서 실행합니다. [k3s 현장 기록](docs/operations/2026-10-22-k3s-web-handoff.md)과 [매일 시작·종료](docs/runbooks/k3s-mysql-daily-operations.md)를 확인합니다. [두 PC MySQL 실행 가이드](docs/operations/shared-pc-docker.md)는 DB 구성 이력과 함께 읽습니다.

## 먼저 읽기

1. [통합 개발 확정 기준 v1.0](docs/contracts/integration-baseline-v1.0.md)
2. [공통 계약 목록](docs/contracts/README.md)
3. [협업 및 커밋 규칙](CONTRIBUTING.md)
4. [환경변수 명세](docs/contracts/environment-variables.md)와 [.env.example](.env.example)

네트워크 주소·서비스 진입점은 2026-10-23 네트워크 정본을 우선합니다. 통합 기준 v1.0의 VLAN·VIP 목표를 현재 적용값으로 사용하지 않습니다.

## 역할과 구조

| 경로 | 내용 | 주 담당 |
|---|---|---|
| `frontend/`, `backend/` | React·Flask·인증·API | A, 문의 C·인시던트 D 공동 |
| `database/` | 스키마·Migration·Seed / 복제·백업·복구 | A / 인프라 담당 |
| `infrastructure/` | Docker·k3s·Nginx·Keepalived | 인프라 담당, NetworkPolicy는 C |
| `network/` | 주소·장비·포트·통신 경로 | C |
| `security/` | pfSense·VPN·Suricata / Wazuh | C / D |
| `monitoring/` | Graylog·Zabbix·n8n·Discord·event-relay | D |
| `tests/` | 기능·보안·통합·부하·관제 검증 | 기능 담당자 공동 |
| `docs/` | 계약·설계·위협 모델·회의·검증 증거 | 전체 |
| `.github/` | Issue 양식·향후 CI | 전체, 설정은 팀장 |

## 시작 순서

- A: 최소 React·Flask와 Health API, DB 모델·단일 Migration 준비.
- 인프라 담당: 격리된 DB 복제·복원 실습, 장비 확인, A 앱 통합 후 이미지 빌드와 공용 PC 검증.
- C: 장비 조건·주소·허용/차단 통신표 작성.
- D: 표준 이벤트·샘플과 Mock API 기반 자동화 준비.
- 최소 연동: 화면 → API → DB → 공유 로그인 → 이벤트 → 티켓 → 알림.

## 고정 기준

- 현재 Web/API Service는 ClusterIP `80` / `5000`; 사용자 접속은 Windows SSH → PC1 VM port-forward → Web Pod입니다.
- NodePort·Ingress·Keepalived·웹/DB VIP는 현재 적용 구성이 아닙니다. PC1은 유일한 k3s control plane이며 DB 자동 승격도 구성하지 않았습니다.
- 서버 세션은 MySQL 공유, Migration은 배포 전 별도 1회 실행.
- 고객 문의와 보안 인시던트는 별도 데이터·권한·API.
- 자동 이벤트 API는 `POST /api/internal/incident-events`.
- 원본 이벤트 중복 키는 `(source, event_id)`.

## GitHub

`main`은 안정 버전, `develop`은 공동 통합 브랜치입니다. 최초 저장소 초기화 이후 작업은 기능 브랜치와 PR로 진행합니다. 테스트·명세·영향 담당자 확인을 포함하고 실제 Secret·개인정보·생 로그는 올리지 않습니다.
