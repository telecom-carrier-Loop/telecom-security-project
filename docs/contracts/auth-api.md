# 인증 계약 — A / C

경로: POST /api/auth/register, /login, /logout; GET /api/auth/me. CSRF 제공 경로·세부 본문은 A의 첫 인증 PR에서 같은 문서에 추가합니다.

MySQL auth_sessions 공유 세션을 사용합니다. 무작위 opaque token 32바이트 이상을 발급하고 DB에는 SHA-256 해시를 저장합니다. 쿠키는 __Host-telecom_session, Secure/HttpOnly/SameSite=Lax, Path=/, Domain 미설정. 유휴 30분·절대 8시간, 로그아웃/비밀번호·역할 변경 시 폐기합니다.

상태 변경은 CSRF와 X-CSRF-Token, 로그인/가입은 JSON·Origin을 검증합니다. 비밀번호는 Argon2id 64MiB/3회/parallelism1/salt16/출력32바이트. 공유 DB 제한은 계정별 15분 5회, IP별 15분 20회, 초과 429+Retry-After입니다.

CUSTOMER는 본인 데이터, SUPPORT_ADMIN은 문의/모의 환불/멤버십 정책, SECURITY_ADMIN은 인시던트를 관리합니다. 공개 가입에서 관리자 역할을 선택하지 않습니다. 두 API 실행본 교차 인증과 고객 간 접근 거부를 검증합니다.
