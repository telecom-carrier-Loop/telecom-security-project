# Migration 정본

A가 Flask-Migrate/Alembic을 이 경로로 초기화합니다. 현재 Migration revision과 설정은 미생성 상태입니다. `backend/migrations/`에 별도 이력을 만들지 않습니다.

B의 일반 API 이미지 빌드 컨텍스트는 backend/입니다. 배포용 Migration은 별도 루트 컨텍스트의 일회성 이미지에 필요한 파일을 포함하여 단일 실행합니다. API Pod 시작 명령에 Migration을 넣지 않습니다.
