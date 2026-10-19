# 버전 잠금 기록 — B / D

2026-10-19 B의 격리 DB·프록시 검증에서 확인한 이미지는 다음과 같습니다. Linux x86_64 Docker 환경에서 검증했고 앱 전체 빌드는 아직 수행하지 않았습니다.

| 검증 대상 | 실제 버전 | 검증한 이미지 참조 |
|---|---|---|
| DB | MySQL 8.4.11 | `mysql:8.4@sha256:24989179f58856db763f418010c1169fecc944e3ec1ea7e921572d83eb070f70` |
| 프록시 | Nginx 1.28.3 | `nginx:1.28-alpine@sha256:a8b39bd9cf0f83869a2162827a0caf6137ddf759d50a171451b335cecc87d236` |

Docker Engine 28.5.1 / Compose 2.40.3-desktop.1. 아래 나머지 값은 기술 계열이며 실행 검증 통과 표시가 아닙니다. [검증 범위](../operations/b-verification.md)를 확인합니다.

| 대상 | 기준 계열 | 최초 검증 PR에서 남길 내용 |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS | 패치·장비 이미지 |
| 프론트 | Node.js 22, React+Vite+TypeScript | Node 패치·package-lock.json·검증 명령 |
| 백엔드 | Python 3.12, Flask+SQLAlchemy | Python 패치·의존성 잠금·검증 명령 |
| DB | MySQL 8.4 | 패치·이미지 digest·복제/드라이버 검증 |
| 클러스터 | k3s·기본 Flannel | 버전·옵션·호환성 |
| 관제 | Wazuh·Graylog·MongoDB·검색 백엔드·Zabbix·n8n | 호환 조합·이미지 digest·영속성 |

앱 발행 이미지는 Commit SHA와 digest를 연결합니다. latest를 사용하거나 도구별 검증 없이 서로 다른 패치를 통합하지 않습니다.
