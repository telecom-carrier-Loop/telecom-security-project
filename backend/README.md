# 백엔드 — A

Python 3.12 + Flask Application Factory + SQLAlchemy를 사용합니다. 현재 앱·의존성·WSGI 코드는 미구현입니다. 첫 구현에서 `wsgi.py`의 `app`과 Gunicorn 실행 포트 5000을 제공합니다.

- `app/core/`: 공통 오류·권한·로깅, `app/models/`: ORM 모델.
- auth/dashboard/plans/support/membership/payments/incidents/health: 기능별 Blueprint.
- 테스트는 `tests/`, Migration 정본은 저장소 루트의 `database/migrations/`입니다.
- DB 세션과 요청 제한을 공유하고, 프로세스 메모리를 인증 정본으로 사용하지 않습니다.
- live/ready를 분리하고 앱 시작 시 자동 Migration은 실행하지 않습니다.
- Dockerfile은 `../infrastructure/docker/backend/Dockerfile`, 컨텍스트는 이 폴더입니다.

[실행 계약](../docs/contracts/runtime.md) · [API 계약](../docs/contracts/api-common.md)
