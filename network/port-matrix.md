# 통신 포트 기준 — 현재 경로와 후속 구성

기준일: 2026-10-23. 필요한 연결/기록을 정리한 표이며 방화벽에 모두 적용된 규칙 목록이 아니다. 학원 전체에 아래 포트를 개방하지 않는다.

## 현재 웹·클러스터·DB

| 출발 → 목적 | 프로토콜 / 포트 | 범위 / 상태 |
|---|---|---|
| PC1 또는 PC2 Windows → PC1 VM | TCP `192.168.7.185:22` | SSH·임시 웹 터널. PC2 접속도 대화에서 확인 |
| 브라우저 → 해당 Windows | TCP `127.0.0.1:18080` | 로컬 SSH listener, 학원망 공개 포트가 아님 |
| SSH → PC1 VM loopback | TCP `127.0.0.1:18080` | kubectl port-forward → 선택된 Web Pod `:80` |
| Web/Nginx Pod → API Service | TCP 5000 | 클러스터 내부 `/api/` 프록시 |
| Web Service → Web Pod | TCP 80 | ClusterIP. NodePort/Ingress/LB 미적용 |
| 두 API Pod → PC1 Primary | TCP `192.168.3.18:3306` | DB 인증·조회 및 노드별 TCP 시험 기록 |
| PC2 Replica → PC1 Primary | TCP 3306 | GTID + TLS 연결. 데이터 흐름은 Primary → Replica |
| PC2 VM → PC1 VM | TCP 6443 | k3s API, 승인 노드만 |
| 두 Ubuntu 노드 간 | UDP 8472 / 필요한 TCP 10250 | Flannel VXLAN / kubelet. 실제 호스트 방화벽 확인 |
| Pod → CoreDNS | TCP/UDP 53 | 클러스터 내부 DNS |

API → Windows DB의 실제 출발지는 overlay/NAT 경로에 따라 확인한다. Pod CIDR이나 `0.0.0.0/0`을 Windows 방화벽에 무조건 허용하지 않는다. VRRP protocol 112, NodePort 30080/30500은 현재 필수 경로가 아니다.

## 관제·자동화: 기록과 연결 계획

| 출발 → 목적 | 프로토콜 / 포트 | 확인 범위 |
|---|---|---|
| 시험 로그 → Graylog Input | UDP 12201 | 10-21 GELF UDP 모의 로그 수신 기록. TCP Input으로 단정하지 않음 |
| 관리자 → Graylog / n8n / Zabbix UI | TCP 9000 / 5678 / 8081 | `monitoring/포트.txt` 기록값. PC별 bind·게시 포트 재확인 |
| Graylog → n8n webhook | HTTP, n8n 수신 5678 기준 | 일부 이벤트·Discord 검증. 다른 PC 배치 시 실제 주소·허용 대상 재설정 |
| Wazuh Agent → Manager | TCP 1514 / 등록 시 1515 | 배치 기준. 실제 신규 VM Agent·경보 전달은 추가 검증 |
| Zabbix active agent → Server | TCP 10051 | 권장 방식. 실제 설치·등록 상태 재확인 |
| 승인 송신기 → event-relay | HTTPS 8443 목표 | 영속 대기·재처리 포함 후속 구현. 현재 listener로 간주하지 않음 |
| n8n → 인시던트 API | 실제 경로 확정 후 지정 | `/api/internal/incident-events`, 전용 토큰, 공개 노출 금지 |
| PC2 백업 감시 / n8n → Discord | HTTPS 443 | 백업 시험 전송·일부 관제 알림 기록. webhook URL 비공개 |
| pfSense → Graylog Syslog Input | UDP, 수신 Input과 일치 | 후속. 기본 514 또는 별도 승인 포트. GELF Input과 구분 |

`host.docker.internal`은 해당 Docker 호스트다. PC1 Graylog → PC2 n8n을 연결할 때 PC1의 `host.docker.internal:5678`을 PC2 주소로 사용하지 않는다. 컨테이너의 `127.0.0.1`도 자기 컨테이너이며 Windows host/다른 PC와 다르다.

## 미확정 진입점

pfSense WAN/LAN/VPN 주소·포트, 외부 HTTPS/DNS, 상시 Web 진입점과 허용 출발지는 후속 설계다. 과거 VIP 443·OpenVPN 10.0.0.0/24·NodePort 예제를 현재 규칙으로 적용하지 않는다.
