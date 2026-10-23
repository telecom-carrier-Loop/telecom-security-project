# k3s·네트워크 — 현재 학원망 기준

2026-10-23: 프로젝트 전용 스위치·VLAN 분리를 사용하지 않는다. [주소](../../network/address-plan.md)와 [구성도](../../network/diagrams/academy-k3s-20261023.md)를 우선한다.

- PC1 `pc1-k3s` / `192.168.7.185`: Server + Worker, 유일한 control plane.
- PC2 `pc2-k3s` / `192.168.7.100`: Agent / Worker. Web Standby 전용 노드가 아니다.
- namespace `telecom`, Deployment/Service `telecom-web`, `telecom-api`; 앱별 replicas 2와 hostname required anti-affinity로 노드별 배치를 구성했다.
- Pod CIDR `10.42.0.0/16`, Service CIDR `10.43.0.0/16`. Flannel VXLAN과 기본 NetworkPolicy 컨트롤러 사용 기준이며 Traefik/ServiceLB는 비활성화했다.
- 현재 Service는 Web ClusterIP `80`, API ClusterIP `5000`. base의 NodePort 30080/30500·VIP 예제를 현재 적용값으로 보지 않는다.
- 접속은 Windows SSH `localhost:18080` → PC1 VM port-forward → 선택된 Web Pod → Web Nginx `/api/` → API Service → API Pod → PC1 Windows DB다. 이 임시 진입점으로 Web 외부 요청 분산·자동 전환을 입증하지 않는다.
- 이미지는 Windows에서 빌드해 두 VM containerd의 `k8s.io`에 같은 새 태그를 반입한다. 현장 `imagePullPolicy`는 `Never`다.
- 실제 배포 사본은 `/home/loop/k3s-app/`다. `infrastructure/kubernetes/base/` 예제를 무조건 전체 apply하지 않는다.

## 정책·장애 한계

VLAN 격리·VIP·외부 Ingress·pfSense 강제 경유는 현재 구성된 것으로 표시하지 않는다. 기본 NetworkPolicy 컨트롤러가 있다는 사실만으로 default-deny 정책 적용을 주장하지 않는다.

후속 정책은 현재 Web Pod → API 5000, API → 실제 Primary 3306, CoreDNS, 승인 관제 경로에 맞춘다. 실제 SNAT·호스트 트래픽 출발지와 허용/거부를 확인한 뒤 적용한다. 과거 VLAN20·DB VIP를 복사하지 않는다.

PC1 전체 장애 시 제어부와 DB Primary가 함께 영향을 받는다. PC2를 제어부로 자동 승격하는 구성은 아니다. required anti-affinity 때문에 노드 하나가 사라져도 같은 앱 두 Pod가 남은 노드에 모두 배치된다고 보장하지 않는다.

[현장 기록](../operations/2026-10-22-k3s-web-handoff.md) · [시작·종료](../runbooks/k3s-mysql-daily-operations.md)
