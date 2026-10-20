"""개발용 명령 (backend 폴더에서 실행).

  python -m flask --app wsgi db upgrade   # MySQL: Migration 적용 (정본 database/migrations, 배포는 B가 1회 실행)
  python -m flask --app wsgi seed         # 합성 데이터 (database/seed/seed_data.py)
  python -m flask --app wsgi seed-demo    # 가상 고객 10명 (database/seed/demo_data.py)
  python -m flask --app wsgi reset-db     # 로컬 SQLite 전용: 지우고 테이블·시드 다시 생성
  python -m flask --app wsgi grant-admin someone@test.local   # 관리자 부여 (웹 화면에서는 회수만 가능)
"""
import importlib.util

import click

from .config import REPO_ROOT
from .extensions import db


def load_seed_module(name: str = "seed_data"):
    path = REPO_ROOT / "database" / "seed" / f"{name}.py"
    if not path.exists():
        raise click.ClickException(f"시드 파일이 없습니다: {path}")
    spec = importlib.util.spec_from_file_location(f"telecom_{name}", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def register_cli(app):
    @app.cli.command("seed")
    def seed():
        module = load_seed_module()
        module.seed_data()
        click.echo(f"seed done — 테스트 계정 비밀번호: {module.TEST_PASSWORD}")

    @app.cli.command("seed-demo")
    def seed_demo():
        """가상 고객 10명 + 관리자 1명 (database/seed/demo_data.py). 빈 DB에 db upgrade 후 실행."""
        module = load_seed_module("demo_data")
        if module.seed_demo():
            click.echo(f"demo seed done — customer01~10@test.local, admin@test.local / {module.TEST_PASSWORD}")
        else:
            click.echo("이미 가상 데이터가 있습니다 (customer01@test.local). 건너뜁니다.")

    @app.cli.command("grant-admin")
    @click.argument("email")
    def grant_admin(email):
        """관리자 권한 부여. 비공개 프로비저닝 원칙에 따라 서버에서만 실행한다."""
        from .core.sessions import revoke_user_sessions
        from .models import User
        user = User.query.filter_by(email=email.strip().lower()).first()
        if user is None:
            raise click.ClickException("해당 이메일의 사용자가 없습니다. 먼저 회원가입하세요.")
        user.role = "ADMIN"
        user.locked_at = user.lock_reason = None
        revoke_user_sessions(user.id)  # 권한 변경 → 세션 폐기 (다시 로그인하면 관리자 화면)
        db.session.commit()
        allowed = app.config.get("ADMIN_ALLOWLIST") or []
        click.echo(f"{user.email} → ADMIN")
        if allowed and user.email not in allowed:
            click.echo("주의: ADMIN_ALLOWLIST 에 없는 계정이라 권한 점검에서 '위반'으로 표시되고 자동 회수 대상이 됩니다.")

    @app.cli.command("reset-db")
    def reset_db():
        if not app.config["SQLALCHEMY_DATABASE_URI"].startswith("sqlite"):
            raise click.ClickException("reset-db 는 로컬 SQLite 전용입니다. MySQL은 db upgrade 를 사용하세요.")
        db.drop_all()
        db.create_all()
        module = load_seed_module()
        module.seed_data()
        click.echo(f"local db reset — 테스트 계정 비밀번호: {module.TEST_PASSWORD}")
