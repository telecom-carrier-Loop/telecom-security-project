# 멤버십 — A / 인프라 담당 / C

예정 경로: GET /api/membership/me, /transactions, /benefits; POST /api/membership/benefits/{id}/redeem.

서버가 비용·등급·자격을 판단하고 차감과 이력을 한 트랜잭션에 저장합니다. Idempotency-Key와 본문 해시·고유 제약을 사용합니다. 같은 키/같은 내용은 기존 결과, 같은 키/다른 내용은 409입니다. 다른 키를 사용한 중복 혜택도 업무 정책·원장 제약으로 확인합니다. SUPPORT_ADMIN 정책 관리는 허용하되 잔액 직접 덮어쓰기 API는 만들지 않습니다.
