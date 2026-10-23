# 주소 기준 — 학원망 / VLAN 미분리

기준일: 2026-10-23. 사용자 화면과 [k3s 현장 기록](../docs/operations/2026-10-22-k3s-web-handoff.md)을 기준으로 한다. 프로젝트가 학원망 주소·게이트웨이·라우팅을 새로 설정했다는 의미는 아니다.

| 계층 / 대상 | 주소 | 역할 / 확인 범위 |
|---|---|---|
| PC1 Windows | `192.168.3.18` | Docker `flask_mysql`, MySQL Primary `:3306` |
| PC2 Windows | `192.168.3.19` | 기존 기록값, 현재 주소 재확인 필요. Docker `mysql-lab`, Replica |
| PC1 Ubuntu VM | `192.168.7.185/24`, `br0`, `pc1-k3s` | k3s Server + Worker, SSH `:22` |
| PC2 Ubuntu VM | `192.168.7.100/24`, `br0`, `pc2-k3s` | k3s Agent / Worker |
| k3s Pod | `10.42.0.0/16` | 클러스터 내부 overlay; 학원망/VLAN 주소가 아님 |
| k3s Service | `10.43.0.0/16` | ClusterIP 주소 공간; 외부 고정 진입 주소가 아님 |
| 각 Windows 브라우저 | `http://localhost:18080` | 해당 Windows의 SSH 터널. PC1·PC2의 localhost는 서로 다름 |
| PC1 VM 포트 전달 | `127.0.0.1:18080` | `telecom-web:80`의 선택된 Web Pod로 전달 |
| PC3 pfSense VM | WAN/LAN/VPN 미확정 | 후속 연결 설계. 새 VPN 대역을 현재 적용값으로 지정하지 않음 |

## 사용 원칙

- 프로젝트 전용 스위치, Trunk, VLAN별 주소·게이트웨이는 사용하지 않는다. 과거 `192.168.10/20/30/40/50.x` 설계와 웹/DB VIP는 현재 적용값이 아니다.
- Windows `192.168.3.x`와 Ubuntu `192.168.7.x/24`를 하나의 `/24`나 동일 L2로 그리지 않는다. 현재 접근 가능한 학원망 경로를 쓰며 실제 라우팅·NAT 경계는 담당자가 확인한다. 두 Ubuntu VM은 VMware 브리지 연결 기준이다.
- VM 주소는 마지막 네트워크 기록에서 DHCP 할당이었다. DHCP 예약/승인된 고정 IP와 PC2 Windows 주소를 확인한다. 게이트웨이·마스크를 추정해 바꾸지 않는다.
- 앱 DB는 `my_new_board_db`이며 두 API Pod 모두 PC1 Primary를 사용한다. PC2 Replica로 앱 쓰기를 분산하지 않는다.
- PC3 Host-only VMnet은 다른 물리 PC의 같은 이름 VMnet과 자동 연결되지 않는다. pfSense 적용 시 실제 NIC·통과 경로부터 확정한다.

[구성도](diagrams/academy-k3s-20261023.md) · [포트](port-matrix.md)
