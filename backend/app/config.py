"""설정. 변수 이름은 docs/contracts/environment-variables.md 를 따른다.

DB는 분리형 변수(DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD)만 사용한다 (DATABASE_URL 사용 안 함).
APP_ENV=local 이고 DB_HOST 가 비어 있으면, MySQL 없이 개인 PC에서 화면·API를 확인할 수 있도록
backend/instance/dev.db (SQLite)를 쓴다. lab 환경에서는 이 대체 동작을 허용하지 않는다.
"""
import os
from pathlib import Path
from urllib.parse import quote_plus

from dotenv import load_dotenv

BACKEND_DIR = Path(__file__).resolve().parent.parent
REPO_ROOT = BACKEND_DIR.parent

# 저장소 루트 .env (팀 공통 템플릿 기준) → backend/.env 순서로 읽는다. 이미 있는 환경변수는 덮어쓰지 않음.
load_dotenv(REPO_ROOT / ".env")
load_dotenv(BACKEND_DIR / ".env")


def _database_uri() -> str:
    host = os.getenv("DB_HOST", "").strip()
    app_env = os.getenv("APP_ENV", "local")
    if not host:
        if app_env != "local":
            raise RuntimeError("DB_HOST가 비어 있습니다. lab 환경은 MySQL 접속 정보가 필요합니다.")
        return "sqlite:///dev.db"  # Flask-SQLAlchemy가 backend/instance/dev.db 로 만든다
    user = quote_plus(os.getenv("DB_USER", ""))
    password = quote_plus(os.getenv("DB_PASSWORD", ""))
    port = os.getenv("DB_PORT", "3306")
    name = os.getenv("DB_NAME", "telecom")
    return f"mysql+pymysql://{user}:{password}@{host}:{port}/{name}?charset=utf8mb4"


class Config:
    APP_ENV = os.getenv("APP_ENV", "local")
    APP_VERSION = os.getenv("APP_VERSION", "0.1.0")
    SQLALCHEMY_DATABASE_URI = _database_uri()
    # DB VIP 전환 후 죽은 연결을 버리고 다시 연결 (통합 기준 11절)
    SQLALCHEMY_ENGINE_OPTIONS = {"pool_pre_ping": True, "pool_recycle": 280}
    JSON_AS_ASCII = False

    LOG_LEVEL = os.getenv("LOG_LEVEL", "INFO")
    LOG_FORMAT = os.getenv("LOG_FORMAT", "json")

    # 인증 (통합 기준 7절)
    SESSION_COOKIE_NAME = "__Host-telecom_session"
    SESSION_IDLE_MINUTES = 30
    SESSION_ABSOLUTE_HOURS = 8
    LOGIN_WINDOW_MINUTES = 15
    LOGIN_MAX_PER_ACCOUNT = 5
    LOGIN_MAX_PER_IP = 20

    # n8n → POST /api/internal/incident-events 전용 토큰 (관리자 세션과 별개)
    INCIDENT_API_TOKEN = os.getenv("INCIDENT_API_TOKEN", "")

    MIGRATIONS_DIR = str(REPO_ROOT / "database" / "migrations")


class TestConfig(Config):
    TESTING = True
    APP_ENV = "local"
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    SQLALCHEMY_ENGINE_OPTIONS = {}
    INCIDENT_API_TOKEN = "test-incident-token"
