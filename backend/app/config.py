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
    # 로컬 실습: Graylog 로 GELF(UDP) 직접 전송. 비워 두면 표준 출력만 사용 (공용 PC 기본)
    GRAYLOG_GELF_HOST = os.getenv("GRAYLOG_GELF_HOST", "").strip()
    GRAYLOG_GELF_PORT = int(os.getenv("GRAYLOG_GELF_PORT", "12201"))
    # 신뢰할 프록시 단계 수. Nginx 뒤(공용 PC·로컬 Compose) 1, Flask 직접 실행 0
    TRUSTED_PROXY_HOPS = int(os.getenv("TRUSTED_PROXY_HOPS", "1"))

    # 인증 (통합 기준 7절)
    SESSION_COOKIE_NAME = "__Host-telecom_session"
    SESSION_IDLE_MINUTES = 30
    SESSION_ABSOLUTE_HOURS = 8
    LOGIN_WINDOW_MINUTES = 15
    LOGIN_MAX_PER_ACCOUNT = 5
    LOGIN_MAX_PER_IP = 20

    # n8n → POST /api/internal/incident-events 전용 토큰 (관리자 세션과 별개)
    INCIDENT_API_TOKEN = os.getenv("INCIDENT_API_TOKEN", "")
    # n8n → 차단·잠금·회수 (/api/internal/ip-blocks, account-locks, role-revocations) 토큰.
    # 팀 결정: 지금은 두 토큰을 같은 값으로 쓴다 → 비워 두면 INCIDENT_API_TOKEN 을 그대로 사용.
    # 나중에 분리할 때는 이 변수에만 다른 값을 넣으면 된다 (코드 수정 없음).
    AUTOMATION_API_TOKEN = os.getenv("AUTOMATION_API_TOKEN") or os.getenv("INCIDENT_API_TOKEN", "")

    # 보안 대시보드
    IP_BLOCK_DEFAULT_MINUTES = int(os.getenv("IP_BLOCK_DEFAULT_MINUTES", "60"))  # 자동 차단 기본 시간
    # 허용된 관리자 이메일 (쉼표 구분). 비어 있으면 권한 점검·자동 회수를 하지 않는다.
    ADMIN_ALLOWLIST = [e.strip().lower() for e in os.getenv("ADMIN_ALLOWLIST", "").split(",") if e.strip()]
    # 방화벽 연동기: none(기본, 앱 차단만) / pfsense(자리만 준비, incidents/firewall.py)
    FIREWALL_PROVIDER = os.getenv("FIREWALL_PROVIDER", "none")

    MIGRATIONS_DIR = str(REPO_ROOT / "database" / "migrations")


class TestConfig(Config):
    TESTING = True
    APP_ENV = "local"
    SQLALCHEMY_DATABASE_URI = "sqlite:///:memory:"
    SQLALCHEMY_ENGINE_OPTIONS = {}
    INCIDENT_API_TOKEN = "test-incident-token"
    GRAYLOG_GELF_HOST = ""
    TRUSTED_PROXY_HOPS = 1
    AUTOMATION_API_TOKEN = "test-incident-token"
    ADMIN_ALLOWLIST = ["admin@test.local"]
    FIREWALL_PROVIDER = "none"
