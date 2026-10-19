# 모의 결제 — A / B / C

예정 경로: GET /api/invoices/me, POST /api/payments, GET /api/payments/{id}, POST /api/admin/payments/{id}/refund.

Mock 결제만 구현합니다. 원 단위 정수·서버 청구서 금액·소유권을 검증합니다. 사용자+작업+Idempotency-Key와 본문 해시를 저장하고 같은 요청은 같은 결과, 내용 충돌은 409입니다. 다른 키라도 동일 청구서 중복 성공을 DB 트랜잭션/상태 검사로 차단합니다. timeout 뒤 쓰기를 무작정 재실행하지 않습니다. 실제 카드·PG Secret은 사용하지 않습니다.
