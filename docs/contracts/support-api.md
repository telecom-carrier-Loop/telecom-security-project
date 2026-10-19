# 고객 문의 — A / C

support_tickets와 support_replies를 사용하고 보안 인시던트와 분리합니다.

예정 경로: GET/POST /api/support, GET/PATCH /api/support/{id}, POST /api/admin/support/{id}/replies.

상태: OPEN / IN_PROGRESS / ANSWERED / CLOSED. 고객은 본인 문의만, SUPPORT_ADMIN은 답변·업무 상태를 관리합니다. 객체 권한과 React 안전 출력을 검증합니다. A가 모델·공통 계약, C가 합의한 UI/검증 모듈을 담당합니다.
