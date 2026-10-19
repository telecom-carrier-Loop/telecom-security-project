# 통신 포트 정본 — C, 인프라 담당/D 확인

| 출발 → 목적 | 프로토콜/포트 | 비고 |
|---|---|---|
| 고객 → 웹 VIP | TCP 443, 80은 HTTPS 이동 | 관리자·내부 API 공개 금지 |
| 호스트 Nginx → VLAN20 노드 | TCP 30080 / 30500 | React 80 / API 5000 |
| API → DB VIP | TCP 3306 | 192.168.30.100 |
| Replica → Primary | TCP 3306 | 데이터 흐름과 연결 시작 방향 구분 |
| PC2 → PC1 VLAN20 | TCP 6443 | k3s API |
| 노드 간 VLAN20 | UDP 8472, 필요한 TCP 10250 | 승인 노드만 |
| VLAN10 호스트 간 | IP protocol 112 | VRRP, TCP/UDP 포트 아님 |
| 관리자 → pfSense | UDP 1194 | OpenVPN |
| VPN/관리망 → VLAN50 | TCP 22 / 승인 UI HTTPS | DB 직접 접근 차단 |
| Agent → Wazuh | TCP 1514, 등록 시 1515 | PC2 VLAN40 |
| 로그 송신 → Graylog | TCP 12201 | PC1 VLAN40 GELF |
| Zabbix Active Agent → Server | TCP 10051 | Passive 10050 기본 비활성 |
| 승인 송신기 → 이벤트 수신기 | TCP 8443 HTTPS | PC2 VLAN40 |
| PC2 내부 | TCP 5678 / 18090 / 18081 | 공용 PC loopback |
| PC2 → Discord | TCP 443 | Secret URL 공개 금지 |

NodePort 30050은 사용하지 않습니다. DNS·NTP·업데이트·관제 내부 포트와 실제 패킷 출발지/SNAT는 C가 장비·서비스 검증 뒤 최소 허용표에 추가합니다. 이 표는 방화벽에 적용된 규칙 목록이 아닙니다.
