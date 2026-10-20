# L∞P 웹 업데이트 정리 — 관리자 통합·회원 목록·요금제 변경·관제 바로가기

- 작성일: 2026-10-19
- 브랜치: `web` (기준 커밋 `4df714c feat(web) : L∞P 웹·DB 1~9단계 초안 구현`)
- 담당: A (웹·DB)
- 커밋 메시지: `feat(admin) : 관리자 역할 통합·회원 목록·요금제 변경·관제 바로가기 추가`
- 테스트: 백엔드 pytest 71개 통과, 프론트 `npm run build`(타입 검사 포함) 통과, 브라우저로 고객·관리자 흐름 확인

---

## 1. 변경 요약

| 구분 | 내용 |
| --- | --- |
| 관리자 통합 | 상담 관리자(`SUPPORT_ADMIN`)와 보안 관리자(`SECURITY_ADMIN`)를 관리자(`ADMIN`) 하나로 합침 |
| 회원 목록 | 관리자가 고객 목록 검색·상세 조회 가능 (목록은 이메일 가림, 상세 열람은 로그 기록) |
| 요금제 | 요금제 카드를 누르면 현재 요금제와 비교표가 열리고, 가입·변경 가능 (모의 처리, 즉시 적용) |
| 관제 바로가기 | 사이드바 로그아웃 아래와 대시보드 하단에 Wazuh·Graylog 링크 추가 (주소는 환경변수) |

---

## 2. 관리자 역할 통합

### 무엇이 바뀌었나
- 역할은 `CUSTOMER` / `ADMIN` 두 가지만 사용한다.
- 관리자 한 명이 문의 답변, 결제 관리(모의 환불), 혜택 정책, 보안 인시던트, 회원 목록을 모두 본다.
- 인시던트 담당자 배정 대상도 `ADMIN` 계정이다.
- 실제 차단은 서버(`roles_required(ROLE_ADMIN)`)가 하고, 화면 메뉴는 사용성용이다.

### 관리자 메뉴 순서
대시보드 → 회원 목록 → 문의 답변 → 결제 관리 → 혜택 정책 → 보안 인시던트
→ (구분선) 프로필 설정 · 고객 화면으로 · 로그아웃
→ (구분선) 관제 도구: Wazuh ↗ · Graylog ↗

### 기존 데이터 변환 (Migration)
- 파일: `database/migrations/versions/c3d9a1f20b6e_merge_admin_roles.py`
- `SUPPORT_ADMIN`, `SECURITY_ADMIN` 계정을 `ADMIN`으로 바꾼다.
- 역할이 바뀌는 계정의 기존 로그인 세션은 폐기한다 (권한 변경 시 세션 폐기 원칙).
- 되돌리기(downgrade)는 원래 어느 쪽 관리자였는지 기록이 없어 지원하지 않는다.

### 테스트 계정 변경
| 이전 | 이후 |
| --- | --- |
| `support@test.local` (상담 관리자) | 삭제 |
| `security@test.local` (보안 관리자) | 삭제 |
| — | `admin@test.local` (관리자) |

고객 계정 `alice@test.local`, `bob@test.local`은 그대로다. 비밀번호는 모두 `Test1234!`.

---

## 3. 회원 목록 (관리자)

| Method | URL | 설명 |
| --- | --- | --- |
| GET | `/api/admin/customers?q=&page=` | 고객 목록 (20명씩, 이름·이메일 검색) |
| GET | `/api/admin/customers/{id}` | 고객 상세 (회선·멤버십·청구·결제·문의) |

- 목록 항목: 이름, 이메일(가림 `al***@test.local`), 요금제, 멤버십 등급, 미납 금액, 진행 중 문의 수, 가입일, 마지막 로그인, 상태
- 상세에서만 전체 이메일을 보여주고, 열람할 때마다 `admin.customer.viewed` 로그를 남긴다 (최소 노출·열람 기록).
- 관리자 계정은 회원 목록 대상이 아니다 (상세 조회 시 404).
- 화면: `frontend/src/features/auth/AdminCustomersPage.tsx`, `AdminCustomerDetailPage.tsx`

---

## 4. 요금제 선택·변경

| Method | URL | 설명 |
| --- | --- | --- |
| POST | `/api/subscriptions/me` | `{ "plan_id": 3 }` → 회선이 없으면 가입(201), 있으면 변경(200) |

- 금액·데이터 제공량은 서버의 `plans` 테이블 값만 사용한다.
- 같은 요금제로 변경하면 409 `SAME_PLAN`.
- 관리자 계정은 요금제를 바꿀 수 없다(403).
- 새로 가입하면 가상 회선 번호(`010-9xxx-xxxx`)와 이번 달 사용량 기록(0)이 생긴다.
- 화면: 요금제 카드 클릭 → 현재 요금제와 비교표(월 요금·데이터·음성·망) → 월 요금 차이 안내 → 변경/가입 버튼

---

## 5. 관제 도구 바로가기

| Method | URL | 설명 |
| --- | --- | --- |
| GET | `/api/admin/monitoring-links` | 관제 도구 이름·주소·설명 (관리자 전용) |

### 환경변수 (새로 추가)
| 변수 | 로컬(`APP_ENV=local`) 기본값 | 설명 |
| --- | --- | --- |
| `WAZUH_DASHBOARD_URL` | `https://localhost` | Wazuh 대시보드 |
| `GRAYLOG_URL` | `http://localhost:9000` | Graylog |
| `ZABBIX_URL` | 없음 (넣으면 표시) | 선택 |
| `N8N_EDITOR_URL` | 없음 (넣으면 표시) | 선택 |

- `http`/`https` 주소만 허용한다 (`javascript:` 같은 값은 무시).
- 공용 PC(lab)에서는 기본값이 없으므로, 관리 Nginx 경로(manage1/manage2.telecom.test)가 정해지면 `.env`에 넣는다. 미설정이면 "주소 미설정"으로 표시된다.
- 링크는 새 탭으로 열린다(`noopener noreferrer`).

---

## 6. 바뀐 파일

### 백엔드
| 파일 | 내용 |
| --- | --- |
| `backend/app/core/permissions.py` | 역할 상수 `ROLE_ADMIN`으로 통합 |
| `backend/app/dashboard/admin_routes.py` | 회원 목록·상세, 관제 링크 API, 대시보드 권한 |
| `backend/app/plans/routes.py` | 요금제 가입·변경 API |
| `backend/app/support/routes.py` | 관리자 권한, 이메일 가리기 함수 |
| `backend/app/incidents/routes.py` | 관리자 권한·담당자 배정 대상 |
| `backend/app/membership/routes.py`, `payments/routes.py`, `models/user.py` | 관리자 권한·주석 |
| `backend/tests/*` | 통합 관리자 기준으로 수정, 회원 목록·요금제·관제 링크 테스트 추가 |

### DB
| 파일 | 내용 |
| --- | --- |
| `database/migrations/versions/c3d9a1f20b6e_merge_admin_roles.py` | 역할 통합 Migration (새 파일) |
| `database/seed/seed_data.py` | 관리자 계정 하나(`admin@test.local`)로 변경 |

### 프론트엔드
| 파일 | 내용 |
| --- | --- |
| `frontend/src/components/common/MonitoringLinks.tsx` | 관제 바로가기 (새 파일) |
| `frontend/src/features/auth/AdminCustomersPage.tsx` | 회원 목록 (새 파일) |
| `frontend/src/features/auth/AdminCustomerDetailPage.tsx` | 회원 상세 (새 파일) |
| `frontend/src/components/layout/AdminLayout.tsx` | 통합 메뉴 + 관제 도구 묶음 |
| `frontend/src/features/dashboard/AdminDashboardPage.tsx` | 모든 타일 링크화, 관제 바로가기 카드 |
| `frontend/src/features/plans/PlansPage.tsx` | 요금제 카드·비교·변경 |
| `frontend/src/app/router/index.tsx` | 관리자 라우트 정리 |
| `frontend/src/services/types.ts`, `utils/format.ts` | `Role` 타입·라벨 |
| 그 밖 | `AdminSupportPage.tsx`, `AdminBenefitsPage.tsx`, `global.css` |

md 문서는 수정하지 않았다.

---

## 7. 로컬 확인 방법

```powershell
# 저장소 루트 .env (DB_HOST 비우면 로컬 SQLite)
APP_ENV=local
DB_HOST=
INCIDENT_API_TOKEN=local-incident-token

# 백엔드
cd backend
.venv\Scripts\activate
python -m flask --app wsgi reset-db
python -m pytest -q          # 71 passed
python run.py

# 프론트 (다른 창)
cd frontend
npm run dev                  # http://localhost:5173
```

| 확인할 것 | 계정 | 기대 결과 |
| --- | --- | --- |
| 요금제 변경 | alice | 카드 클릭 → 비교표 → 변경 완료 문구, 홈의 요금제 이름 변경 |
| 관리자 메뉴 | admin | 사이드바에 회원 목록·보안 인시던트가 함께 보임 |
| 회원 목록 | admin | 2명, 이메일 가림, 검색 동작, 이름 클릭 시 상세 |
| 관제 바로가기 | admin | 사이드바·대시보드에 Wazuh·Graylog 링크 |
| 권한 차단 | alice | `/admin` 주소로 가도 고객 홈으로 돌아감 |

공용 MySQL에는 `reset-db` 대신 `python -m flask --app wsgi db upgrade`(B가 배포 전 1회 실행)로 역할 변환 Migration을 적용한다.

---

## 8. 팀과 맞출 것

| 항목 | 내용 | 확인할 사람 |
| --- | --- | --- |
| 역할 구성 변경 | `integration-baseline-v1.0.md` 7절의 3역할(CUSTOMER·SUPPORT_ADMIN·SECURITY_ADMIN)과 다름 → 계약 문서 갱신 필요 | 팀장, C |
| 새 환경변수 | `WAZUH_DASHBOARD_URL`, `GRAYLOG_URL` 등 → `.env.example`, `environment-variables.md`에 추가 요청 | B |
| 관제 도구 주소 | 공용 PC에서 쓸 관리 Nginx 경로 확정 | B, D |
| 회원 정보 노출 범위 | 목록은 이메일 가림, 상세는 전체 + 열람 기록 — 이 수준이 적절한지 | C |
| PR 대상 | 이번 PR은 base `develop`, compare `web` (지난 PR #2는 main으로 합쳐졌음) | 팀장 |

---

## 9. 다음 작업 후보 (아직 미반영)

### n8n 연결 — 실습과 비슷하게 맞추는 안
| 구분 | 노션 실습 | 추천안 |
| --- | --- | --- |
| 티켓 Webhook | `/webhook/incident` | 그대로 사용 (`N8N_WEBHOOK_URL`을 D·B와 변경) |
| 차단 Webhook | `/webhook/ip-block` | 그대로 |
| Wazuh Webhook | `/webhook/wazuh-alert` | 그대로 |
| 티켓 API | 게시판 API | `POST /api/internal/incident-events` (구현됨) |
| 차단 API | `POST /api/admin/block` | `POST /api/internal/ip-blocks` (계약상 자동화는 `/api/admin` 사용 불가) |
| 인증 | `X-API-Key` | `X-API-Key`도 받도록 확장 → 실습 노드를 거의 그대로 재사용 |

Graylog Notification 본문은 표준 이벤트 형식으로 바꿔야 한다 (severity 소문자, `event_id`에 `${event.id}`).

### 보안 대시보드 추가 후보
| 우선순위 | 기능 | 근거 |
| --- | --- | --- |
| ★★★ | 차단 IP 관리 (목록·사유·남은 시간·해제) | SOAR ③, S11, Wazuh 통합 실습 |
| ★★★ | 화이트리스트 (관리자·게이트웨이 IP 자동 차단 방지) | SOAR ③ 7.1 |
| ★★★ | 오탐 처리 (오탐/정탐 판정 + 연결된 차단 해제) | SOAR ③ 7.4, 심야 로그인 |
| ★★☆ | 탐지 경로별 현황 (Wazuh·Graylog·Suricata·앱) | Wazuh 통합 실습 |
| ★★☆ | 상위 공격 출발지 IP | 모든 실습의 `src_ip` 집계 |
| ★★☆ | 심야·이상 로그인 의심 계정 | 심야 로그인 실습 (T1078) |
| ★★☆ | 소스별 마지막 수신 시각 (끊김 감지) | S11 트러블슈팅 |
| ★☆☆ | 자동화 처리 상태 / 알림 발송 이력 | 계약 13절, 3채널 알림 |

결정 필요: 차단을 앱(L7)에서 할지 pfSense(C)와 나눌지, 실습처럼 같은 `src_ip` 티켓을 합칠지(계약은 `(source, event_id)` 기준).
