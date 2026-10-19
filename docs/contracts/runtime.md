# 실행 계약 — 인프라 담당 / A

Node.js 22, Python 3.12, Flask+SQLAlchemy, MySQL 8.4, Ubuntu Server 24.04 LTS를 기준으로 합니다. 정확한 패치/digest는 [versions.md](versions.md)에 최초 검증 후 기록합니다.

- frontend/: `npm ci` → `npm run build`, 산출물 dist/. package.json/lock 초안이 main에 추가됨.
- backend/: Gunicorn `wsgi:app`, 포트 5000. wsgi.py/의존성 초안이 main에 추가됨.
- API: GET /api/health/live, /api/health/ready, /api/version 예정.
- local Compose: HTTPS 8443, HTTP 8080은 HTTPS로 이동, DB는 외부 포트 미공개.
- 공용 PC: 앱은 k3s, DB/관제는 전용 실행 구성. 같은 앱을 중복 기동하지 않음.
- Dockerfile 정본은 infrastructure/docker/{frontend,backend}/Dockerfile, 컨텍스트는 각 앱 폴더.
- Migration은 별도 루트 컨텍스트 일회성 이미지에서 단일 실행. 앱 시작 명령에 넣지 않음.

인프라 담당자의 Dockerfile·로컬 Compose·격리 DB 실습과 두 공용 PC의 MySQL Compose를 작성했습니다. 앱 초안은 추가되었으며 실제 Docker 앱 이미지 빌드·서비스 전체 연동은 별도 검증합니다. 현재 공용 PC는 Windows Docker Desktop이며 [두 PC 실행 가이드](../operations/shared-pc-docker.md)를 우선 적용합니다.
