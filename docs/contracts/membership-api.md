# 멤버십 — A / 인프라 담당 / C

예정 경로: GET /api/membership/me, /transactions, /benefits; POST /api/membership/benefits/{id}/redeem.

서버가 비용·등급·자격을 판단하고 차감과 이력을 한 트랜잭션에 저장합니다. Idempotency-Key와 본문 해시·고유 제약을 사용합니다. 같은 키/같은 내용은 기존 결과, 같은 키/다른 내용은 409입니다. 다른 키를 사용한 중복 혜택도 업무 정책·원장 제약으로 확인합니다. ADMIN 정책 관리는 허용하되 잔액 직접 덮어쓰기 API는 만들지 않습니다.

## 등급 및 관리자 변경 (2026-10-29)

| rank | 표시 등급 | 공개 code | 기존 DB code | 기존 적립률 |
|---|---|---|---|---|
| 0 | 일반유저 | GENERAL | BASIC | 0.5% |
| 1 | Plus | PLUS | SILVER | 1% |
| 2 | VIP | VIP | GOLD | 2% |

고객 멤버십은 일반유저·Plus·VIP 세 등급이다. ADMIN은 users.role의 관리자 역할이며 구매·지정 가능한 고객 멤버십이 아니다. 과거 rank 3 행·외래키·포인트 원장은 삭제하거나 일괄 변경하지 않고, 고객 조회·신규 적립·혜택·상점 조건에서는 VIP(rank 2) 정책으로 호환한다. 기존 잔액은 보존한다. 관리자 지정 후 요금제 변경으로 등급을 덮어쓰지 않는다.

- `GET /api/membership/tiers`: 로그인 후 고객용 세 등급 조회. Admin 등급은 반환하지 않는다.
- `GET /api/admin/membership/tiers`: 실제 ADMIN 세션만 고객용 세 등급 목록 조회 가능.
- `PATCH /api/admin/membership/customers/{user_id}/tier`: 실제 ADMIN 세션과 CSRF 검증. 본문 `{ "rank": 0~2 정수, "reason": "1~300자 변경 사유" }`. rank 3은 422로 거부한다.
- 대상은 활성 CUSTOMER 계정이다. 탈퇴 계정은 409, 없는 대상이나 실제 ADMIN 계정은 404다.
- 미가입 고객을 지정하면 포인트 0의 멤버십을 생성한다. 기존 회원의 잔액·원장은 변경하지 않는다. 가입 보너스를 추가 지급하지 않는다.
- 변경 전후 rank·사유·행위자·대상을 `security_audit_logs`의 `membership.tier.changed`로 변경과 같은 트랜잭션에 저장한다.
- 동시 변경 충돌은 409로 반환한다. 실제 사용자 role·세션 권한·허용목록은 변경하지 않는다.

## 업그레이드 카드

현재 구매 금액·실제 결제 연동은 미구현이다. 업그레이드 버튼은 `결제 시스템은 준비중입니다.` 안내창만 표시한다. 고객의 rank를 직접 바꾸는 구매 API를 열지 않으며, 성공 결제 없이 등급을 갱신하지 않는다. 추후 결제 연동 시 서버에서 금액·결제 성공·소유권·중복 처리를 검증한 뒤 등급을 변경해야 한다.
