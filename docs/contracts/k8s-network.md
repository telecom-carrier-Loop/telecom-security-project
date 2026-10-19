# k3s·네트워크 — 인프라 담당 / C

PC1 Server+Worker, PC2 Agent. namespace=telecom, app=telecom-web / telecom-api. Pod CIDR=10.42.0.0/16, Service CIDR=10.43.0.0/16, node-ip=각 VLAN20 주소.

기본 Flannel VXLAN+NetworkPolicy 컨트롤러를 사용하고 Traefik/ServiceLB는 비활성화합니다. Web/API 각각 replicas2+hostname required anti-affinity, RollingUpdate maxSurge0/maxUnavailable1. 정상 두 노드에서만 일반 롤링 배포를 시작합니다.

NodePort Web30080/API30500, externalTrafficPolicy=Local, 호스트 Nginx가 양 노드 분산·실패 제외합니다. 로컬 Pod 없는 노드는 처리하지 못합니다.

기본 ingress/egress 차단과 필수 허용을 함께 준비합니다. API ingress는 실제 호스트 Nginx 출발지, API egress는 DB VIP192.168.30.100/32:3306 및 CoreDNS TCP/UDP53 기준입니다. Web Pod만 API 소스로 가정하지 않습니다. 호스트·NodePort 예외는 별도 방화벽/직접접근 검증이 필요합니다.

PC1 단일 제어부 장애에서 전체 자동 HA를 보장하지 않습니다. 실제 labels·DNS·바인딩·정책 적용은 워크로드 구현 PR에서 확인합니다.
