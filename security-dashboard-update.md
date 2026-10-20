# L∞P 보안 대시보드 업데이트 — 차단 IP·계정 잠금·권한 점검·자동화 현황

- 작성일: 2026-10-20
- 브랜치: `web` (이전 커밋 `7f9e562 feat(admin) : 관리자 역할 통합·회원 목록·요금제 변경·관제 바로가기 추가` 다음)
- 커밋 메시지(제안): `feat(security) : 차단 IP·화이트리스트·계정 잠금·권한 점검·자동화 현황 추가`
- 테스트: 백엔드 pytest **89개 통과** (보안 대시보드 신규 16개 포함), 프론트 타입 검사·빌드 통과, 브라우저 확인 완료
- 근거: 실습 보안 게시판(회원 권한 관리·차단 IP 목록)과 n8n 워크플로 1·4·5·6·7·8·9번

---

## 1. 이번에 만든 것

| 화면 (관리자 → 보안) | 하는 일 |
| --- | --- |
| **회원 목록 · 계정 보안** | 상태(정상·잠김·탈퇴) 필터, 15분 로그인 실패 수, 잠금 시각·사유, 개별/선택 잠금·해제, 탈퇴 처리 |
| **차단 IP** | 차단 목록(차단 중/전체 기록), 쉼표로 여러 개 차단, 차단 시간 선택(30분~7일·영구), 선택 해제, 검색, 재접근 횟수, 방화벽 연동 상태, **화이트리스트** |
| **권한 점검** | 관리자 목록 + 허용목록(`ADMIN_ALLOWLIST`) 밖 관리자 "정책 위반" 표시, 회수 |
| **자동화 현황** | n8n 워크플로 7개별 마지막 처리 시각·오늘/7일 건수·처리 종류, Webhook ↔ 웹 API 대응표 |
| 운영 대시보드 | 차단 중인 IP·잠긴 계정·권한 정책 위반 타일 추가 |

요청 반영 사항
- 계정 보안: **처리자 열 없음** (누가 했는지는 `security_audit_logs`에만 남김)
- 차단 IP: **해제 예정 시각은 관리자 화면에서만** 보임. 차단된 사용자는 "보안 정책에 따라 접근이 차단되었습니다" 문구만 받고, 응답 본문·헤더(`Retry-After`)에 시각이 없음. n8n 응답에도 시각을 넣지 않음
- 화이트리스트: 추가 시 그 주소의 현재 차단을 바로 해제, loopback(127.0.0.1, ::1)은 기본 등록

실습과 다르게 만든 부분
| 실습 게시판 | L∞P | 이유 |
| --- | --- | --- |
| 회원 삭제(게시글까지) | **탈퇴 처리**(비활성화, 기록 보존) | 청구·결제 기록 보존 |
| 웹에서 admin 부여 | 웹은 **회수만**, 부여는 `python -m flask --app wsgi grant-admin 이메일` | 관리자는 비공개 프로비저닝 (과잉 권한 시나리오 차단) |
| gold 등급 부여 | 없음 | L∞P 등급은 요금제로 정해지는 멤버십 |
| 자동화가 관리자도 잠금 | 관리자는 **잠그지 않음**(ADMIN_PROTECTED) | 관리 화면 잠김 방지 |
| 자동화가 해제·부여 | 자동화는 **차단·잠금·회수만** | 토큰이 새도 권한 상승 불가 |
| 본인·마지막 관리자 회수 | **금지** | Self-lockout 방지 |

---

## 2. 차단 위치와 방화벽 연동 자리 (결정 1)

### 지금 동작
```
요청 → (Nginx) → Flask before_request: guard_blocked_ip()
                    ├─ /api/health, /api/internal 은 검사 안 함
                    ├─ 화이트리스트 → 통과
                    └─ ip_blocks 에 차단 중 → 403 IP_BLOCKED (재접근 횟수 +1, 첫 재접근만 이벤트)
```
- 클라이언트 IP는 `ProxyFix(x_for=1)`로 승인된 한 단계 프록시(호스트 Nginx)의 `X-Forwarded-For`만 반영
- React 정적 파일은 Nginx가 주므로 화면은 열리지만, 로그인·데이터 API가 모두 403

### 방화벽을 붙이는 자리
- 파일: `backend/app/incidents/firewall.py`
- 차단·해제 직후 `get_firewall().block()/release()`가 호출되고, 결과가 `ip_blocks.firewall_status`에 저장됨
  - `SKIPPED` 연동 없음(지금 기본) · `PENDING` 연동기 있음, 미반영 · `SYNCED` 반영 · `FAILED` 실패(앱 차단은 유지)
- 환경변수 `FIREWALL_PROVIDER=none`(기본) / `pfsense`(자리만 준비, `PfSenseFirewall` 클래스에 TODO)

### 붙이는 방법 (C와 협의할 제안 2가지)
| 방법 | 내용 | 장점 |
| --- | --- | --- |
| A. 앱이 직접 | pfSense 별칭 `LOOP_BLOCKLIST` + WAN→VIP 차단 규칙, `PfSenseFirewall`에서 REST API로 별칭에 IP 추가/삭제 | 수동·자동 차단 모두 한 곳에서 반영 |
| B. n8n이 이어서 | 앱은 `none` 유지, n8n 워크플로에서 `ip-blocks` 응답 뒤에 pfSense 노드 추가 | 앱 코드 변경 없음, C가 n8n에서 직접 관리 |

예정 환경변수(A안): `PFSENSE_API_URL`, `PFSENSE_API_KEY`, `PFSENSE_ALIAS` → Secret으로 주입, `environment-variables.md` 갱신 필요

---

## 3. 토큰 (결정 2)

| 변수 | 쓰는 곳 | 지금 값 |
| --- | --- | --- |
| `INCIDENT_API_TOKEN` | `POST /api/internal/incident-events` | 팀 공용 값 |
| `AUTOMATION_API_TOKEN` | `ip-blocks`, `account-locks`, `privilege-violations`, `role-revocations` | **비워 두면 INCIDENT_API_TOKEN과 같은 값 사용** |

- 헤더는 `Authorization: Bearer <토큰>` 또는 실습 방식 `X-API-Key: <토큰>` 둘 다 가능
- 나중에 분리할 때는 `.env`에 `AUTOMATION_API_TOKEN`만 다른 값으로 넣으면 됨 (코드 수정 없음)
- 선택 헤더 `X-Workflow: 4-ip-block` → 자동화 현황에서 워크플로별로 묶임

---

## 4. 새 이벤트 이름 (결정 3)

모든 이벤트는 기존 표준 형식(`schema_version`, `source=flask-api`, `event_id`, `event_type`, `detected_at`, `severity`, `title`, `asset`, `request_id`, `evidence`)을 그대로 따른다. 아래는 **추가된 10개**이며, D의 `event-schema.md` 이벤트 목록에 추가 요청이 필요하다.

| event_type | severity | 언제 | evidence 필드 | 발생 위치 |
| --- | --- | --- | --- | --- |
| `security.ip.blocked` | medium | IP 차단 등록 (수동·자동) | `ip`, `block_source`(MANUAL/AUTOMATION), `workflow`, `minutes`, `firewall_status` | `incidents/protection.py` `block_ip()` |
| `security.ip.released` | info | 관리자 해제, 화이트리스트 등록으로 인한 해제 | `ip`, `reason` | `_release()` |
| `security.ip.block_hit` | medium | 차단된 IP가 처음 다시 접근 (차단 1건당 1회) | `ip`, `block_id`, `path` | `guard_blocked_ip()` |
| `security.whitelist.changed` | info | 화이트리스트 추가·삭제 | `cidr`, `change`(added/removed) | `add_whitelist()`, `remove_whitelist()` |
| `auth.account.locked` | medium | 계정 잠금 (수동·8번 봇) | `target_user_id`, `lock_source`(ADMIN/AUTOMATION), `workflow` | `lock_user()` |
| `auth.account.unlocked` | info | 관리자 잠금 해제 | `target_user_id` | `unlock_user()` |
| `auth.account.login_locked` | medium | 잠긴 계정으로 로그인 (비밀번호가 맞은 경우만) | `target_user_id` | `auth/service.py` `authenticate()` |
| `auth.account.deactivated` | info | 관리자 탈퇴 처리 | `target_user_id` | `deactivate_user()` |
| `auth.privilege.violation` | high | 1번 봇이 허용목록 밖 관리자를 조회할 때 1명당 1건 | `target_user_id`, `workflow` | `GET /api/internal/privilege-violations` |
| `auth.role.revoked` | high | 관리자 권한 회수 (수동·1번 봇) | `target_user_id`, `revoke_source`, `workflow` | `revoke_admin()` |

설계 메모
- `block_hit`는 매 요청마다 남기면 로그가 폭주하므로 첫 재접근만 이벤트, 나머지는 `ip_blocks.hit_count`로 집계
- `login_locked`는 비밀번호가 틀리면 일반 `auth.login.failed`와 똑같이 처리 → 잠김 여부로 계정 존재를 알 수 없게 함
- `role.revoked`·`privilege.violation`은 권한 관련이라 high
- n8n이 이 이벤트를 다시 인시던트로 올리면 `source=flask-api`, `event_id`가 그대로 유지되어 중복 티켓이 생기지 않음

---

## 5. 필요한 DB 전체 목록 (결정 4)

### 5.1 테이블 요약 (21개)

| 테이블 | 용도 |
| --- | --- |
| `auth_login_failures` | 로그인 실패 기록 (계정 해시·IP 해시별 15분 제한) |
| `auth_sessions` | MySQL 공유 서버 세션 (토큰 해시·CSRF·만료) |
| `benefit_redemptions` | 멤버십 혜택 사용 기록 (멱등 키) |
| `benefits` | 멤버십 혜택 정책 |
| `incident_histories` | 인시던트 대응 이력 |
| `invoices` | 월별 청구서 |
| `ip_blocks` | **(신규)** 차단 IP 목록 — 앱(L7) 차단, 방화벽 연동 상태 |
| `ip_whitelist` | **(신규)** 차단 제외 주소 (IP·CIDR) |
| `membership_accounts` | L∞P+ 멤버십 계정·포인트 잔액 |
| `membership_tiers` | 멤버십 등급 |
| `payment_events` | 결제 상태 변경 이력 |
| `payments` | 모의 결제 (멱등 키·성공 청구서 UNIQUE) |
| `plans` | 요금제 |
| `point_transactions` | 포인트 원장 (업무 식별자 UNIQUE) |
| `security_audit_logs` | **(신규)** 보안 작업 기록 — 차단·잠금·회수·자동 수신 (자동화 현황의 원본) |
| `security_incidents` | 보안 인시던트 (source+event_id UNIQUE) |
| `subscriptions` | 회선 가입 |
| `support_replies` | 문의 답변 |
| `support_tickets` | 고객 문의 |
| `usage_records` | 월별 사용량 |
| `users` | 회원·관리자 (**변경**: locked_at, lock_reason 추가 / 역할 CUSTOMER·ADMIN) |

### 5.2 Migration 순서 (`database/migrations/versions/`)

| 순서 | 파일 | 내용 |
| --- | --- | --- |
| 1 | `b72e4713f5b9_initial_schema.py` | 초기 18개 테이블 |
| 2 | `c3d9a1f20b6e_merge_admin_roles.py` | SUPPORT_ADMIN·SECURITY_ADMIN → ADMIN, 해당 세션 폐기 |
| 3 | `35853b957d28_security_dashboard.py` | **(신규)** `ip_blocks`, `ip_whitelist`, `security_audit_logs` 생성, `users.locked_at`·`lock_reason` 추가, loopback 화이트리스트 기본값 |

공용 MySQL: `python -m flask --app wsgi db upgrade` (B가 배포 전 1회) / 로컬 SQLite: `reset-db`

### 5.3 테이블별 컬럼 (모델에서 자동 추출)

#### `auth_login_failures`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| key_type | VARCHAR(10) | N |  |
| key_hash | VARCHAR(64) | N |  |
| created_at | DATETIME | N |  |

- INDEX(key_type, key_hash, created_at)

#### `auth_sessions`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| token_hash | VARCHAR(64) | N | UNIQUE |
| user_id | INTEGER | N | FK → users.id, INDEX |
| csrf_token | VARCHAR(64) | N |  |
| created_at | DATETIME | N |  |
| last_seen_at | DATETIME | N |  |
| expires_at | DATETIME | N | INDEX |
| revoked_at | DATETIME | Y |  |


#### `benefit_redemptions`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| user_id | INTEGER | N | FK → users.id, INDEX |
| benefit_id | INTEGER | N | FK → benefits.id |
| points_spent | INTEGER | N |  |
| status | VARCHAR(20) | N |  |
| idempotency_key | VARCHAR(64) | N |  |
| request_hash | VARCHAR(64) | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |

- UNIQUE(user_id, idempotency_key)

#### `benefits`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| name | VARCHAR(60) | N |  |
| partner | VARCHAR(40) | N |  |
| required_points | INTEGER | N |  |
| min_tier_rank | INTEGER | N |  |
| monthly_limit | INTEGER | N |  |
| is_active | BOOLEAN | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `incident_histories`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| incident_id | INTEGER | N | FK → security_incidents.id, INDEX |
| actor_id | INTEGER | Y | FK → users.id |
| action | VARCHAR(30) | N |  |
| note | TEXT | Y |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `invoices`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| user_id | INTEGER | N | FK → users.id, INDEX |
| subscription_id | INTEGER | N | FK → subscriptions.id |
| period | VARCHAR(7) | N |  |
| amount | INTEGER | N |  |
| due_date | DATE | N |  |
| status | VARCHAR(20) | N | INDEX |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |

- UNIQUE(subscription_id, period)

#### `ip_blocks`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| ip | VARCHAR(45) | N | INDEX |
| reason | VARCHAR(200) | N |  |
| source | VARCHAR(20) | N |  |
| workflow | VARCHAR(64) | Y |  |
| created_by | INTEGER | Y | FK → users.id |
| created_at | DATETIME | N |  |
| expires_at | DATETIME | Y | INDEX |
| released_at | DATETIME | Y |  |
| released_by | INTEGER | Y | FK → users.id |
| hit_count | INTEGER | N | 기본값 0 |
| last_hit_at | DATETIME | Y |  |
| firewall_status | VARCHAR(10) | N | 기본값 SKIPPED |
| firewall_ref | VARCHAR(128) | Y |  |


#### `ip_whitelist`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| cidr | VARCHAR(49) | N | UNIQUE |
| memo | VARCHAR(100) | Y |  |
| created_by | INTEGER | Y | FK → users.id |
| created_at | DATETIME | N |  |


#### `membership_accounts`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| user_id | INTEGER | N | FK → users.id, UNIQUE |
| tier_id | INTEGER | N | FK → membership_tiers.id |
| point_balance | INTEGER | N |  |
| version | INTEGER | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |

- CHECK: `point_balance >= 0`

#### `membership_tiers`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| code | VARCHAR(20) | N | UNIQUE |
| name | VARCHAR(30) | N |  |
| min_monthly_fee | INTEGER | N |  |
| rank | INTEGER | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `payment_events`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| payment_id | INTEGER | N | FK → payments.id, INDEX |
| event_type | VARCHAR(30) | N |  |
| from_status | VARCHAR(20) | Y |  |
| to_status | VARCHAR(20) | N |  |
| detail | VARCHAR(255) | Y |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `payments`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| user_id | INTEGER | N | FK → users.id, INDEX |
| invoice_id | INTEGER | N | FK → invoices.id, INDEX |
| transaction_ref | VARCHAR(64) | N | UNIQUE |
| idempotency_key | VARCHAR(64) | N |  |
| request_hash | VARCHAR(64) | N |  |
| success_invoice_id | INTEGER | Y | FK → invoices.id, UNIQUE |
| amount | INTEGER | N |  |
| method | VARCHAR(20) | N |  |
| status | VARCHAR(20) | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |

- UNIQUE(user_id, idempotency_key)

#### `plans`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| code | VARCHAR(30) | N | UNIQUE |
| name | VARCHAR(50) | N |  |
| monthly_fee | INTEGER | N |  |
| data_mb | INTEGER | N |  |
| voice_minutes | INTEGER | N |  |
| network | VARCHAR(5) | N |  |
| is_active | BOOLEAN | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `point_transactions`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| account_id | INTEGER | N | FK → membership_accounts.id, INDEX |
| amount | INTEGER | N |  |
| balance_after | INTEGER | N |  |
| kind | VARCHAR(20) | N |  |
| business_ref | VARCHAR(64) | N | UNIQUE |
| memo | VARCHAR(100) | Y |  |
| redemption_id | INTEGER | Y | FK → benefit_redemptions.id |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `security_audit_logs`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| actor_type | VARCHAR(12) | N |  |
| actor_id | INTEGER | Y | FK → users.id |
| workflow | VARCHAR(64) | Y | INDEX |
| action | VARCHAR(40) | N | INDEX |
| target_type | VARCHAR(20) | N |  |
| target | VARCHAR(255) | N |  |
| result | VARCHAR(20) | N |  |
| reason | VARCHAR(200) | Y |  |
| created_at | DATETIME | N | INDEX |


#### `security_incidents`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| source | VARCHAR(30) | N |  |
| event_id | VARCHAR(128) | N |  |
| event_type | VARCHAR(60) | N |  |
| event_hash | VARCHAR(64) | N |  |
| severity | VARCHAR(10) | N | INDEX |
| title | VARCHAR(200) | N |  |
| description | TEXT | Y |  |
| asset_host | VARCHAR(64) | Y |  |
| asset_service | VARCHAR(64) | Y |  |
| scenario_id | VARCHAR(64) | Y |  |
| origin_request_id | VARCHAR(128) | Y |  |
| evidence_json | TEXT | Y |  |
| status | VARCHAR(20) | N | INDEX |
| assigned_to | INTEGER | Y | FK → users.id |
| detected_at | DATETIME | N |  |
| resolved_at | DATETIME | Y |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |

- UNIQUE(source, event_id)

#### `subscriptions`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| user_id | INTEGER | N | FK → users.id, INDEX |
| plan_id | INTEGER | N | FK → plans.id |
| phone_number | VARCHAR(20) | N | UNIQUE |
| status | VARCHAR(20) | N |  |
| started_on | DATE | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `support_replies`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| ticket_id | INTEGER | N | FK → support_tickets.id, INDEX |
| author_id | INTEGER | N | FK → users.id |
| content | TEXT | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `support_tickets`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| user_id | INTEGER | N | FK → users.id, INDEX |
| category | VARCHAR(30) | N |  |
| title | VARCHAR(120) | N |  |
| content | TEXT | N |  |
| status | VARCHAR(20) | N | INDEX |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |


#### `usage_records`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| subscription_id | INTEGER | N | FK → subscriptions.id |
| period | VARCHAR(7) | N |  |
| data_used_mb | INTEGER | N |  |
| voice_used_minutes | INTEGER | N |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |

- UNIQUE(subscription_id, period)

#### `users`

| 컬럼 | 타입 | NULL | 키·제약 |
| --- | --- | --- | --- |
| id | INTEGER | N | PK |
| email | VARCHAR(255) | N | UNIQUE, INDEX |
| password_hash | VARCHAR(255) | N |  |
| name | VARCHAR(50) | N |  |
| role | VARCHAR(20) | N |  |
| is_active | BOOLEAN | N |  |
| last_login_at | DATETIME | Y |  |
| previous_login_at | DATETIME | Y |  |
| failed_attempts_before_login | INTEGER | N | 기본값 0 |
| password_changed_at | DATETIME | Y |  |
| locked_at | DATETIME | Y |  |
| lock_reason | VARCHAR(200) | Y |  |
| created_at | DATETIME | N |  |
| updated_at | DATETIME | N |  |




---

## 6. n8n 연결표

| 워크플로 | n8n Webhook | 웹 API | 요청 본문 예 | 응답 |
| --- | --- | --- | --- | --- |
| 4-ip 차단봇 | `/webhook/ip-block` | `POST /api/internal/ip-blocks` | `{"src_ip":"203.0.113.44","reason":"5회 실패","minutes":60}` | 201 CREATED / 200 ALREADY·WHITELISTED |
| 9-S11 Snort IP 차단봇 | `/webhook/snort-ip-block` | `POST /api/internal/ip-blocks` | `{"ip":"198.51.100.77","reason":"포트스캔"}` | 〃 |
| 8-브루트포스 계정잠금봇 | `/webhook/login-bruteforce` | `POST /api/internal/account-locks` | `{"username":"alice@test.local","reason":"브루트포스"}` | 201 / 200 ALREADY·NOT_FOUND·ADMIN_PROTECTED |
| 7-Wazuh 경보봇 | `/webhook/wazuh-alert` | `POST /api/internal/incident-events` (+필요시 ip-blocks) | 표준 이벤트 | 201 / 200 deduplicated / 409 / 422 |
| 6-인시던트 리포트봇 | `/webhook/incident` | `POST /api/internal/incident-events` | 표준 이벤트 | 〃 |
| 5-복합 공격 경보봇 | `/webhook/security-alert` | `POST /api/internal/incident-events` | 표준 이벤트 (`event_type` 예: `auth.password_spray`) | 〃 |
| 1-자동 회수 봇 | `/webhook/priv-guard` | `GET /api/internal/privilege-violations` → `POST /api/internal/role-revocations` | `{"email":"rogue@test.local"}` | 201 REVOKED / 200 IN_ALLOWLIST·NOT_ADMIN·ALLOWLIST_NOT_SET |
| 2·3 hping 테스트 | 필요 없음 | — | — | 네트워크 영역(C·D) |

공통 헤더: `Content-Type: application/json`, `X-API-Key: <토큰>`(또는 `Authorization: Bearer`), `X-Workflow: <위 key>`
주소: 내 PC에서 Flask 직접 실행 + n8n Docker → `http://host.docker.internal:5000/api/internal/...` / 공용 PC → `http://127.0.0.1:18081/api/internal/...`
Graylog가 Docker 안에 있으면 n8n Webhook 주소도 `http://host.docker.internal:5678/webhook/...`

---

## 7. 새 환경변수

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `AUTOMATION_API_TOKEN` | (= INCIDENT_API_TOKEN) | 차단·잠금·회수 토큰 |
| `ADMIN_ALLOWLIST` | 비어 있음 → 권한 점검 꺼짐 | 허용 관리자 이메일, 쉼표 구분 (예: `admin@test.local`) |
| `IP_BLOCK_DEFAULT_MINUTES` | 60 | 자동 차단 기본 시간(분) |
| `FIREWALL_PROVIDER` | none | 방화벽 연동기 (`pfsense`는 자리만) |

`.env.example`·`environment-variables.md` 추가는 B에게 요청

---

## 8. 바뀐 파일

| 구분 | 파일 |
| --- | --- |
| 신규 백엔드 | `app/models/protection.py`, `app/incidents/protection.py`, `app/incidents/protection_routes.py`, `app/incidents/firewall.py`, `tests/test_protection.py` |
| 수정 백엔드 | `app/__init__.py`(차단 검사·라우트 등록), `config.py`(새 변수), `core/logging.py`(이벤트 10개), `core/sessions.py`(잠긴 계정 세션 거부), `auth/service.py`(잠긴 계정 로그인 거부), `dashboard/admin_routes.py`(회원 보안 정보·대시보드 숫자), `incidents/routes.py`(X-API-Key·자동화 기록), `models/user.py`·`models/__init__.py`, `cli.py`(grant-admin), `tests/test_admin.py`·`test_incidents.py` |
| DB | `database/migrations/versions/35853b957d28_security_dashboard.py`(신규), `database/seed/seed_data.py`(화이트리스트·시드 차단 1건) |
| 신규 프론트 | `features/incidents/AdminIpBlocksPage.tsx`, `AdminPrivilegesPage.tsx`, `AdminAutomationPage.tsx` |
| 수정 프론트 | `features/auth/AdminCustomersPage.tsx`, `features/dashboard/AdminDashboardPage.tsx`, `components/layout/AdminLayout.tsx`(보안 메뉴), `app/router/index.tsx`, `services/types.ts`, `utils/format.ts`, `styles/global.css` |

---

## 9. 로컬 확인

```powershell
# .env 에 추가
ADMIN_ALLOWLIST=admin@test.local

cd backend
.venv\Scripts\activate
python -m flask --app wsgi reset-db
python -m flask --app wsgi grant-admin bob@test.local   # 정책 위반 시연용 (선택)
python -m pytest -q                                     # 89 passed
python run.py
```

n8n 흉내 (PowerShell)
```powershell
$h = @{ "X-API-Key" = "local-incident-token"; "X-Workflow" = "4-ip-block" }
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:5000/api/internal/ip-blocks -ContentType "application/json" -Headers $h -Body '{"src_ip":"198.51.100.7","reason":"5회 실패"}'
$h["X-Workflow"] = "8-login-bruteforce"
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:5000/api/internal/account-locks -ContentType "application/json" -Headers $h -Body '{"username":"alice@test.local","reason":"브루트포스"}'
```

| 확인 | 기대 결과 |
| --- | --- |
| alice 로그인 | "보안 정책에 따라 잠긴 계정입니다" |
| 관리자 → 회원 목록 → 잠김 필터 | alice, 사유 표시, 해제 버튼 |
| 관리자 → 차단 IP | 198.51.100.7(자동화 4-ip-block), 해제 예정 시각 보임 |
| 차단 IP에 127.0.0.1 입력 | "화이트리스트라 제외" |
| 관리자 → 권한 점검 | bob "위반" + 회수 버튼 |
| 관리자 → 자동화 현황 | 4번·8번 "동작 중", 오늘 1건 |

---

## 10. 팀과 맞출 것

| 항목 | 담당 |
| --- | --- |
| 이벤트 10개를 `event-schema.md`에 추가, Graylog·Wazuh 수집 규칙 | D |
| 방화벽 연동 방식(A안/B안), pfSense 별칭 이름 | C |
| 새 환경변수 4개 `.env.example`·`environment-variables.md` 반영 | B |
| `/api/internal/*` 외부 비노출(공개·관리 Nginx) 재확인 | B·C |
| n8n 워크플로에 `X-Workflow` 헤더 추가, 실습 URL `/api/admin/block` → `/api/internal/ip-blocks` | D |
| 관리자 역할 통합·허용목록 정책을 `integration-baseline` 7절에 반영 | 팀장 |
