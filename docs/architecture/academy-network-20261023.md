# 학원망·VM k3s 네트워크 재구성 근거

2026-10-23 / 저장소와 사용자 실행 화면 기준. 구성도·문서만 변경하며 실제 IP·라우팅·방화벽·DB·Kubernetes 설정을 변경하지 않는다.

## 이전 그림에서 변경한 내용

| 이전 구성 | 현재 기준 |
|---|---|
| 관리형 스위치·VLAN10~50·Trunk·SPAN | 제거. 기존 학원망을 cloud로 표시하고 프로젝트 VLAN을 구성하지 않음 |
| PC1 MAIN / PC2 Web STANDBY | 양쪽 Web·API 실행, DB만 Primary/Replica |
| Ubuntu 안에 DB·관제까지 배치 | Ubuntu VM k3s 웹과 Windows Docker DB·관제 분리 |
| VIP·Keepalived·NodePort가 현재 진입점 | SSH → PC1 VM port-forward → Web Pod, 외부 자동 HA로 표시하지 않음 |
| 모든 통신이 pfSense·Suricata 경유 | PC3 NIC·주소·통과 경로 미확정, 후속으로 표시 |
| App DB / Incident DB를 별도 서버로 표시 | 현재 my_new_board_db 안의 업무·인시던트 테이블, 같은 Primary 사용 |
| 관제 전체 미구현 또는 전체 완료 | 일부 모의 경보/알림 검증과 실제 수집·티켓의 미검증 구분 |

## 근거 파일과 판정

| 근거 | 확인 범위 |
|---|---|
| [10-22 k3s 현장 기록](../operations/2026-10-22-k3s-web-handoff.md) | 노드 IP·브리지·ClusterIP·Nginx·API·DB·18080 접속, pfSense 미확정 |
| 사용자 10-23 실행 화면 | 두 Deployment Ready 2, 이미지 반입 과정, PC2 SSH에서 PC1 hostname·HTTP 200, 이후 PC2 브라우저 접속 복구 보고 |
| [매일 운영](../runbooks/k3s-mysql-daily-operations.md), [예약 백업](../runbooks/mysql84-backup-schedule.md), [복원·Discord](../runbooks/mysql84-restore-discord.md) | Windows DB·PC2 예약 작업·격리 복원, 역할 변경·단일 제어부 한계 |
| [10-21 관제 일지](../../monitoring/진행%20상황/2026.10.21%20작업_현황_김준오.md) | GELF UDP 12201 → Graylog → n8n → Discord 일부 모의 검증; 실제 Wazuh와 구분 |
| [10-22 관제 일지](../../monitoring/진행%20상황/2026.10.22%20작업_현황_김준오.md) | 패킷 캡처·분석 전달. Wazuh 룰·새 VM 중앙 수집·API 조치 추가 검증 |
| monitoring/포트.txt, n8n JSON 노드 유형 | UI 포트·설정 파일 존재. 최종 물리 배치·활성 노드·API 실행 성공의 증거는 아님 |
| 기존 주소·포트·k8s-network·traffic-flow·baseline-v1.0 | 과거 VLAN/VIP/NodePort 목표와 실제 상태가 충돌하여 정본과 우선순위 수정 |

webhook URL·토큰·Secret·SQL 백업은 문서·그림에 복사하지 않았다. 릴리스마다 달라지는 이미지 태그도 현재값으로 고정하지 않았다. 새 이미지·DB 마이그레이션 완료는 릴리스별 증거로 판단하며 웹 접속 복구만으로 완료 판정하지 않는다.

## 관제 배치와 연결

- PC1: MySQL Primary와 별개 실행 자원에 Graylog·MongoDB·호환 검색 백엔드.
- PC2: Replica·백업, Wazuh Manager/Indexer/Dashboard, Zabbix + 전용 DB, n8n. event-relay는 후속 영속 수신기.
- 각 Windows·Ubuntu VM: Agent·앱/Nginx 로그 수집. 4GB k3s VM 두 대에 관제 전체를 넣는 배치가 아니다.
- 위는 배치 기준안이다. 일부 구동·모의 경보는 확인됐지만 최종 PC별 위치와 끝단 연결은 재확인한다.
- PC1 Graylog → PC2 n8n에는 승인된 PC2 실제 주소를 사용한다. host.docker.internal은 해당 Docker 호스트이며 PC2의 별칭이 아니다.
- 인시던트 API는 POST /api/internal/incident-events + 전용 토큰이다. 외부에 개발용 내부 API를 그대로 게시하지 않고 승인 서비스 경로를 확정한다.
- PC2 로컬 백업은 PC2 전체 장애·공통 저장장치 장애를 견디는 외부 사본이 아니다. 원격 감시·외부 사본은 남은 작업이다.

## pfSense·탐지 후속 확인

1. 학원망 승인 범위, PC3 NIC/VMnet, WAN/LAN 주소·관리 접속. VLAN 미분리는 WAN/LAN 같은 서브넷을 의미하지 않는다.
2. 기존 VM·DB 주소를 유지할 실제 경유 경로, 상시 웹 endpoint·TLS·프록시 헤더·클라이언트 IP.
3. 학원망 우회 접근에 대한 호스트 방화벽과 Pod 허용/거부 시험. VLAN 없는 구성을 보안 격리 완료로 평가하지 않는다.
4. pfSense Syslog Input과 Suricata 관측 인터페이스, Agent/로그 전달. SPAN 없이 학교 전체 트래픽을 수집한다고 주장하지 않는다.
5. PC1 제어부 장애·DB 수동 승격·앱 접속 변경·백업 역할 보완·복구 시간 검증.

## 기술 근거

- [K3s 기본 네트워크](https://docs.k3s.io/networking/basic-network-options): overlay와 기존망 구분.
- [kubectl port-forward](https://kubernetes.io/docs/reference/kubectl/generated/kubectl_port-forward/): 선택 Pod 종료 시 전달 세션 재실행 필요.
- [pfSense 원격 Syslog](https://docs.netgate.com/pfsense/en/latest/monitoring/logs/remote.html): 수신기와 UDP 포트 일치.
- [Suricata 인터페이스](https://docs.suricata.io/en/latest/quickstart.html): 실제 관측 인터페이스 명시.

[구성도와 Mermaid 원본](../../network/diagrams/academy-k3s-20261023.md)
