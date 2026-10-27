# 인시던트 — A / D, C 검증

자동 수신: POST /api/internal/incident-events, 전용 INCIDENT_API_TOKEN 사용. 관리자 세션을 재사용하지 않고 관리자 API 권한도 부여하지 않습니다. 공개·관리 Nginx는 이 경로를 외부에 노출하지 않습니다. 학원망 k3s의 PC2 n8n 전용 HTTPS(10443) 준비·적용·검증은 [자동화 입구 절차](../runbooks/academy-automation-ingress.md)를 따릅니다. 실제 랩 연결 완료 전까지 준비 상태로 기록합니다.

수동 업무: /api/admin/incidents/*, 현재 구현의 ADMIN 세션으로 조회·생성·배정·상태·이력 관리. 변경 요청은 CSRF를 검사합니다.

표준 이벤트는 [event-schema](observability/event-schema.md)를 따릅니다. DB 고유 제약은 (source,event_id), 정규화 본문 해시는 수신 시각·수집기·재시도 횟수를 제외합니다.

| 결과 | 응답 |
|---|---|
| 최초 | 201, incident_id |
| 같은 키/같은 원본 | 200, 기존 incident_id, deduplicated=true |
| 같은 키/다른 원본 | 409 |
| 잘못된 입력 | 422 |
| 인증/권한 | 401/403 |
| 의존성 장애 | 503; timeout은 결과 불명으로 별도 추적 |

상태는 OPEN → INVESTIGATING → RESOLVED → CLOSED, RESOLVED 재개 시 INVESTIGATING으로 되돌리고 이력을 남깁니다. n8n은 티켓 결과와 Discord 결과를 분리하여 재시도합니다.
