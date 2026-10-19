# 실행·배포 구조 — B

- docker/frontend, docker/backend: Dockerfile 예정 위치. 각 컨텍스트는 앱 폴더.
- docker/compose/local: 개인 PC 통합, pc1/pc2: 공용 PC의 DB·관제 전용 구성.
- kubernetes/base·overlays: Web/API Deployment와 Service.
- kubernetes/network-policies: C 소유 정책, B가 실제 연결 검증.
- nginx·keepalived·k3s: 호스트 웹 진입점·웹 VIP·노드 설정.

현재 실행 설정은 작성하지 않았습니다. 런타임과 이미지 digest를 검증한 후 추가합니다. 공용 PC 웹/API를 Compose와 k3s로 동시에 기동하지 않습니다.

[실행 계약](../docs/contracts/runtime.md) · [k3s 네트워크](../docs/contracts/k8s-network.md) · [포트](../network/port-matrix.md)
