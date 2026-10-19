# 실행·배포 구조 — 인프라 담당

- docker/frontend, docker/backend: 앱 Dockerfile. 각 컨텍스트는 앱 폴더, Migration은 저장소 루트.
- docker/compose/local: 개인 PC 앱 통합. shared-pc/pc1.yaml·pc2.yaml: Windows Docker Desktop 두 PC의 MySQL 복제 구성.
- kubernetes/base·overlays: Web/API Deployment와 Service.
- kubernetes/network-policies: C 소유 정책, 인프라 담당자가 실제 연결 검증.
- nginx·keepalived·k3s: 호스트 웹 진입점·웹 VIP·노드 설정.

local Compose, db-lab과 공용 PC용 MySQL Compose를 작성했습니다. 앱 초안은 main에 추가되었고 실제 앱 이미지 연동은 별도 검증합니다. k3s·호스트 Nginx·Keepalived는 Linux 환경용 템플릿이며 현재 Windows Docker Desktop에 그대로 적용하지 않습니다. 관제 실행 구성과 Windows 환경의 웹 VIP는 후속 작업입니다.

[두 PC 실행 가이드](../docs/operations/shared-pc-docker.md) · PowerShell 도구: tools/shared-pc.ps1

[인프라 시작 가이드](../docs/operations/infra-start-here.md) · [검증 기록](../docs/operations/infra-verification.md)

[실행 계약](../docs/contracts/runtime.md) · [k3s 네트워크](../docs/contracts/k8s-network.md) · [포트](../network/port-matrix.md)
