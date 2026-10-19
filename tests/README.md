# 검증 구조

현재 실행 테스트 코드는 없습니다. 각 기능 구현 PR에서 의미 있는 정상·오류 경로 검증을 추가합니다.

- backend/tests/: Flask 단위/API.
- tests/auth·support·membership·payments/: 기능별 공동 검증.
- security/scenarios/: C의 승인된 웹·네트워크 시나리오.
- integration/: 브라우저→API→DB 및 분야 간 연동.
- load/: B의 한도 있는 부하·중단 조건.
- monitoring/: D의 합성 이벤트·수집·중복·실패·재처리.

최초 목표는 최소 화면→Flask→MySQL→로그 1건입니다. 이후 교차 Pod 인증, 정책 허용/차단, 동일 이벤트 3회→티켓 1개, Discord 실패, 백업 복원과 장애 전환을 검증합니다.

증거에는 환경·버전·Commit·테스트 ID·예상/실제·request_id/event_id/incident_id를 기록하고 미실행을 성공으로 표시하지 않습니다. 실서비스 공격·실제 개인정보·무제한 부하 시험은 범위 밖입니다.
