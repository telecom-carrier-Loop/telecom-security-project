# 통신 경로 — C / B / D

고객 → pfSense NAT → 웹 VIP 192.168.10.100 → 호스트 Nginx → VLAN20 NodePort 30080/30500 → Web/API → DB VIP 192.168.30.100:3306.

관리자는 OpenVPN → VLAN50 관리 주소/SSH. 공개 Nginx는 /admin 및 /api/admin·/api/internal 경로/하위 경로를 거부합니다. 관리 Nginx도 /api/internal은 공개하지 않습니다.

센서/앱 로그 → Wazuh/Graylog/Zabbix → PC2 이벤트 수신 HTTPS8443 → 별도 SQLite 영속 대기 → n8n → loopback 내부 프록시18081 → 인증된 Incident API → DB → 관리자 화면 / 별도 Discord.

프록시 upstream 소스는 각 VLAN20 노드 주소로 고정합니다. Pod·Service·VLAN은 다른 주소 계층입니다. 동일 호스트/L2 우회, DNAT/SNAT·노드 트래픽을 실제로 검증하고 호스트 방화벽을 함께 적용합니다.

[포트 정본](../../network/port-matrix.md)
