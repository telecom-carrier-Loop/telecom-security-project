# 관제·자동화 — D

- PC1: Graylog+MongoDB+호환 검색 백엔드.
- PC2: Wazuh 전체, Zabbix와 전용 DB, n8n, event-relay.
- event-relay/: 인증된 이벤트 수신·SQLite WAL 영속 대기·재처리 서비스 예정 위치.
- n8n/: 비밀정보를 제거한 Workflow와 샘플.
- discord/: 메시지·실패·중복 억제 정책.
- samples/redacted/: 합성·비식별 로그만 보관.

이벤트 수신 저장소와 n8n 내부 DB는 분리합니다. 티켓과 알림 성공을 별도로 추적하고 DB 고유 제약으로 티켓 중복을 방지합니다. PC2 장애 관측은 PC1의 별도 확인 경로를 준비합니다. 현재 도구 설정·구동·연동은 미구현입니다.

[이벤트 계약](../docs/contracts/observability/event-schema.md) · [인시던트 API](../docs/contracts/incident-api.md)
