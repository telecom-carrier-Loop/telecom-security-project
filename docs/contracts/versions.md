# 버전 잠금 기록 — B / D

현재 앱·이미지 빌드를 아직 수행하지 않았으므로 검증된 패치·digest는 없습니다. 아래 값은 기술 계열이며 실행 검증 통과 표시가 아닙니다.

| 대상 | 기준 계열 | 최초 검증 PR에서 남길 내용 |
|---|---|---|
| OS | Ubuntu Server 24.04 LTS | 패치·장비 이미지 |
| 프론트 | Node.js 22, React+Vite+TypeScript | Node 패치·package-lock.json·검증 명령 |
| 백엔드 | Python 3.12, Flask+SQLAlchemy | Python 패치·의존성 잠금·검증 명령 |
| DB | MySQL 8.4 | 패치·이미지 digest·복제/드라이버 검증 |
| 클러스터 | k3s·기본 Flannel | 버전·옵션·호환성 |
| 관제 | Wazuh·Graylog·MongoDB·검색 백엔드·Zabbix·n8n | 호환 조합·이미지 digest·영속성 |

앱 발행 이미지는 Commit SHA와 digest를 연결합니다. latest를 사용하거나 도구별 검증 없이 서로 다른 패치를 통합하지 않습니다.
