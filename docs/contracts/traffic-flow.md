# 통신 경로 — 학원망 / VM k3s

기준일: 2026-10-23. [구성도](../../network/diagrams/academy-k3s-20261023.md)와 [주소](../../network/address-plan.md)를 따른다.

## 현재 웹

```text
PC1 또는 PC2 Windows 브라우저: http://localhost:18080
 → 그 Windows의 SSH 로컬 터널
 → PC1 Ubuntu 192.168.7.185:22
 → PC1 VM 127.0.0.1:18080 / kubectl port-forward
 → 선택된 Web Pod :80
 → Nginx /api/ → telecom-api ClusterIP :5000
 → PC1 또는 PC2의 Flask Pod
 → PC1 Windows 192.168.3.18:3306 / my_new_board_db
```

Windows마다 localhost가 다르므로 각 Windows에 터널이 필요하다. Web Pod 두 개가 있어도 port-forward는 하나를 선택한다. Service 이름을 쓴다는 이유로 외부 Web 요청이 양 Pod에 분산되는 것은 아니다.

현재 경로는 VLAN·전용 스위치·VIP·pfSense NAT를 필수 경유하지 않는다. `/admin`·`/api/internal`의 외부 경계 차단이나 외부 HTTPS까지 완료됐다고 해석하지 않는다.

## DB·백업

- 앱 읽기·쓰기는 PC1 Primary를 사용한다.
- 복제 연결은 PC2 Replica → PC1 Primary TCP 3306, 데이터는 Primary → Replica로 적용한다. GTID + TLS이며 양방향 복제가 아니다.
- PC2 예약 백업 → 파일 보관 → 격리 RestoreTest → 백업 감시 도구 → Discord 경로다. 자격 증명·백업은 Git에 올리지 않는다.
- PC2 승격·앱 접속 변경·백업 역할 보완은 별도 후속 작업이다. 복제/백업이 있다는 사실은 자동 장애 전환을 뜻하지 않는다.

## 관제·인시던트

- 일부 확인: 모의 GELF UDP 로그 → Graylog 이벤트 → n8n → Discord. 실제 Wazuh Agent 탐지와 구분한다.
- 후속: 호스트/VM Agent·로그 → Wazuh·Graylog·Zabbix → event-relay 영속 대기 → n8n → 인증된 `/api/internal/incident-events` → DB → 관리자 화면. 티켓·Discord 결과를 따로 검증한다.
- PC1 Graylog / PC2 Wazuh·Zabbix·n8n은 배치 기준이다. 최종 위치·Input·게시 포트·노드 활성 상태를 재확인한다. cross-PC 연결에 `host.docker.internal`이나 컨테이너 localhost를 쓰지 않는다.

## PC3 pfSense / VPN / Suricata 후속

WAN/LAN·NIC·학원망 정책·원격 관리 진입점을 확정한 뒤 실제 통과 경로를 만든다. VLAN 미분리가 라우터 WAN/LAN의 같은 서브넷 배치를 뜻하지 않는다.

pfSense/Suricata는 실제 경유하거나 해당 인터페이스에 보이는 트래픽만 관측한다. SPAN을 전제하지 않으며 학원망 전체·HTTPS 본문·overlay 전체를 수집한다고 표시하지 않는다. Agent·앱 로그 전달을 기본 관제 경로로 삼는다.

[포트](../../network/port-matrix.md) · [분석 근거](../architecture/academy-network-20261023.md)
