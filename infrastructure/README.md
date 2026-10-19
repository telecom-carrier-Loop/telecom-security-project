# 실행·배포 구조 — B

- docker/frontend, docker/backend: 앱 Dockerfile. 각 컨텍스트는 앱 폴더, Migration은 저장소 루트.
- docker/compose/local: 개인 PC 통합, pc1/pc2: 공용 PC의 DB·관제 전용 구성.
- kubernetes/base·overlays: Web/API Deployment와 Service.
- kubernetes/network-policies: C 소유 정책, B가 실제 연결 검증.
- nginx·keepalived·k3s: 호스트 웹 진입점·웹 VIP·노드 설정.

local Compose와 별도 db-lab 실습을 작성했습니다. k3s·Nginx·Keepalived는 장비 확인 전 템플릿입니다. 앱 빌드에는 A 코드가 필요합니다. 공용 PC용 DB·관제 실행 구성은 후속 작업이며 공용 PC 웹/API를 Compose와 k3s로 동시에 기동하지 않습니다.

[B 시작 가이드](../docs/operations/b-start-here.md) · [검증 기록](../docs/operations/b-verification.md)

[실행 계약](../docs/contracts/runtime.md) · [k3s 네트워크](../docs/contracts/k8s-network.md) · [포트](../network/port-matrix.md)
