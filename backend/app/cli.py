"""개발용 명령 (backend 폴더에서 실행).

  python -m flask --app wsgi db upgrade   # MySQL: Migration 적용 (정본 database/migrations, 배포는 B가 1회 실행)
  python -m flask --app wsgi seed         # 합성 데이터 (database/seed/seed_data.py)
  python -m flask --app wsgi reset-db     # 로컬 SQLite 전용: 지우고 테이블·시드 다시 생성
"""
import importlib.util

import click

from .config import REPO_ROOT
from .extensions import db


def load_seed_module():
    path = REPO_ROOT / "database" / "seed" / "seed_data.py"
    if not path.exists():
        raise click.ClickException(f"시드 파일이 없습니다: {path}")
    spec = importlib.util.spec_from_file_location("telecom_seed_data", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def register_cli(app):
    @app.cli.command("seed")
    def seed():
        module = load_seed_module()
        module.seed_data()
        click.echo(f"seed done — 테스트 계정 비밀번호: {module.TEST_PASSWORD}")

    @app.cli.command("reset-db")
    def reset_db():
        if not app.config["SQLALCHEMY_DATABASE_URI"].startswith("sqlite"):
            raise click.ClickException("reset-db 는 로컬 SQLite 전용입니다. MySQL은 db upgrade 를 사용하세요.")
        db.drop_all()
        db.create_all()
        module = load_seed_module()
        module.seed_data()
        click.echo(f"local db reset — 테스트 계정 비밀번호: {module.TEST_PASSWORD}")
