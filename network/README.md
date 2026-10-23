# 네트워크 — C

2026-10-23 기준은 **학원 기존 네트워크 + 두 Ubuntu VM의 k3s + Windows Docker DB/관제**입니다. 프로젝트 전용 스위치·Trunk·SPAN·VLAN 분리를 전제로 하지 않습니다. 학원 자체 인프라는 기존망으로 추상화하며 변경하지 않습니다.

- [현재 구성도: PNG와 수정 가능한 Mermaid](diagrams/academy-k3s-20261023.md)
- [주소 정본](address-plan.md) · [포트 정본](port-matrix.md)
- [통신 경로](../docs/contracts/traffic-flow.md) · [분석 근거](../docs/architecture/academy-network-20261023.md)

확인된 경로와 후속 설계를 구분합니다. PC3 pfSense의 주소·NIC·강제 경유는 미확정이며 현재 SSH 임시 진입점은 웹 자동 HA가 아닙니다. 서로 다른 IP 대역이 있다는 이유로 프로젝트 VLAN이 존재한다고 해석하지 않습니다.

`diagrams/`에는 비밀정보를 제거한 구성도만 보관합니다.
