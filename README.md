# Telecom carrier Loop — 통신사 보안 프로젝트

React·Flask·MySQL 고객 포털에 네트워크 접근 통제, 보안 관제, 인시던트 자동화와 장애 복구 실습을 연결하는 4인 Monorepo입니다.

## 현재 상태

기본 디렉터리와 개발 계약을 준비했습니다. 앱 코드, 의존성·잠금 파일, Dockerfile, Compose, k3s 매니페스트 및 실제 장비 설정은 아직 구현하지 않았습니다. 현재 저장소만으로 서비스를 실행할 수는 없습니다. `.gitkeep`은 빈 작업 폴더를 Git에 보관하기 위한 파일입니다.

## 먼저 읽기

1. [통합 개발 확정 기준 v1.0](docs/contracts/integration-baseline-v1.0.md)
2. [공통 계약 목록](docs/contracts/README.md)
3. [협업 및 커밋 규칙](CONTRIBUTING.md)
4. [환경변수 명세](docs/contracts/environment-variables.md)와 [.env.example](.env.example)

기존 가이드의 예시와 다르면 통합 확정 기준을 적용합니다. 요약 문서가 정본과 달라지지 않도록 같은 PR에서 갱신합니다.

## 역할과 구조

| 경로 | 내용 | 주 담당 |
|---|---|---|
| `frontend/`, `backend/` | React·Flask·인증·API | A, 문의 C·인시던트 D 공동 |
| `database/` | 스키마·Migration·Seed / 복제·백업·복구 | A / B |
| `infrastructure/` | Docker·k3s·Nginx·Keepalived | B, NetworkPolicy는 C |
| `network/` | 주소·장비·포트·통신 경로 | C |
| `security/` | pfSense·VPN·Suricata / Wazuh | C / D |
| `monitoring/` | Graylog·Zabbix·n8n·Discord·event-relay | D |
| `tests/` | 기능·보안·통합·부하·관제 검증 | 기능 담당자 공동 |
| `docs/` | 계약·설계·위협 모델·회의·검증 증거 | 전체 |
| `.github/` | Issue 양식·향후 CI | 전체, 설정은 팀장 |

## 시작 순서

- A: 최소 React·Flask와 Health API, DB 모델·단일 Migration 준비.
- B: 실행 계약 확인 후 앱 이미지와 로컬 Compose 준비.
- C: 장비 조건·주소·허용/차단 통신표 작성.
- D: 표준 이벤트·샘플과 Mock API 기반 자동화 준비.
- 최소 연동: 화면 → API → DB → 공유 로그인 → 이벤트 → 티켓 → 알림.

## 고정 기준

- React NodePort `30080`, API NodePort `30500`, API 내부 `5000`.
- 웹 VIP `192.168.10.100`은 자동 전환, DB VIP `192.168.30.100`은 수동 전환.
- 서버 세션은 MySQL 공유, Migration은 배포 전 별도 1회 실행.
- 고객 문의와 보안 인시던트는 별도 데이터·권한·API.
- 자동 이벤트 API는 `POST /api/internal/incident-events`.
- 원본 이벤트 중복 키는 `(source, event_id)`.

## GitHub

`main`은 안정 버전, `develop`은 공동 통합 브랜치입니다. 최초 저장소 초기화 이후 작업은 기능 브랜치와 PR로 진행합니다. 테스트·명세·영향 담당자 확인을 포함하고 실제 Secret·개인정보·생 로그는 올리지 않습니다.
