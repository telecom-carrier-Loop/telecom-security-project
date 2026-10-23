# 관제·자동화 — D

- PC1: Graylog+MongoDB+호환 검색 백엔드.
- PC2: Wazuh 전체, Zabbix와 전용 DB, n8n, event-relay.
- event-relay/: 인증된 이벤트 수신·SQLite WAL 영속 대기·재처리 서비스 예정 위치.
- n8n/: 비밀정보를 제거한 Workflow와 샘플.
- discord/: 메시지·실패·중복 억제 정책.
- samples/redacted/: 합성·비식별 로그만 보관.

위 배치는 **배치 기준안**이며 실제 호스트별 설치 상태는 재확인합니다. 도구들은 4GB k3s 웹 VM 안에 모두 넣지 않고 Windows Docker 또는 별도 자원으로 운영합니다.

10-21/10-22 진행 일지에는 Graylog GELF UDP 모의 로그 → n8n → Discord의 일부 검증과 실제 패킷 수집 기록이 있습니다. 관제 전체를 미구현으로 보지 않습니다. 다만 실제 Wazuh Agent/Manager 탐지, 신규 k3s VM 중앙 로그, API 조치·티켓, event-relay 영속 재처리는 별도 검증/구현 영역입니다. 워크플로 파일 존재만으로 활성 실행 성공을 주장하지 않습니다.

이벤트 수신 저장소와 n8n 내부 DB는 분리합니다. 티켓과 알림 결과를 따로 추적하고 DB 고유 제약으로 중복을 방지합니다. PC2 장애 관측은 PC1의 별도 경로를 준비합니다. 학원망 관제는 에이전트·명시적 로그 전달 중심이며 SPAN 스위치를 전제하지 않습니다.

[현재 네트워크 구성도](../network/diagrams/academy-k3s-20261023.md) · [포트와 cross-PC 연결](../network/port-matrix.md)

[이벤트 계약](../docs/contracts/observability/event-schema.md) · [인시던트 API](../docs/contracts/incident-api.md)
