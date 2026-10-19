# 대시보드·요금제 — A

예정 경로: GET /api/dashboard/summary, /api/plans, /api/subscriptions/me, /api/usage/me.

인증 사용자 기준으로 가입 요금제·사용량·청구·멤버십을 조회합니다. 클라이언트 임의 user_id로 다른 고객 데이터를 조회하지 않습니다. 상세 DTO·필터는 첫 구현 PR에서 작성하고 본인/타인 계정·빈 데이터·오류 상태를 검증합니다.
