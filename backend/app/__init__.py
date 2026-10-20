"""Flask Application Factory (WSGI: backend/wsgi.py 의 app, 포트 5000)."""
from flask import Flask
from werkzeug.middleware.proxy_fix import ProxyFix

from .config import Config
from .core.errors import register_error_handlers
from .core.logging import setup_logging
from .extensions import db, migrate


def create_app(config_class=Config) -> Flask:
    app = Flask(__name__)
    app.config.from_object(config_class)

    # 승인된 한 단계 프록시(호스트 Nginx)만 신뢰한다 (통합 기준 6절)
    app.wsgi_app = ProxyFix(app.wsgi_app, x_for=1, x_proto=1, x_host=1)

    db.init_app(app)
    # Migration 정본은 저장소 루트 database/migrations/ (backend/migrations 를 만들지 않음)
    migrate.init_app(app, db, directory=app.config["MIGRATIONS_DIR"])

    from . import models  # noqa: F401  (Migration·create_all 이 테이블을 인식하도록)

    setup_logging(app)
    register_error_handlers(app)
    _register_blueprints(app)

    # 차단 IP 검사 → 세션 로드 순서 (차단된 IP는 세션 조회 전에 403)
    from .incidents.protection import guard_blocked_ip
    app.before_request(guard_blocked_ip)
    from .core.sessions import init_sessions
    init_sessions(app)

    from .cli import register_cli
    register_cli(app)
    return app


def _register_blueprints(app: Flask) -> None:
    from .dashboard.admin_routes import bp as admin_bp
    from .auth.routes import bp as auth_bp
    from .dashboard.routes import bp as dashboard_bp
    from .health.routes import bp as health_bp
    from .incidents.protection_routes import bp as protection_bp
    from .incidents.routes import bp as incidents_bp
    from .membership.routes import admin_bp as membership_admin_bp
    from .membership.routes import bp as membership_bp
    from .payments.routes import bp as payments_bp
    from .plans.routes import bp as plans_bp
    from .support.routes import bp as support_bp

    for bp in (health_bp, auth_bp, dashboard_bp, plans_bp, support_bp,
               membership_bp, membership_admin_bp, payments_bp, incidents_bp, protection_bp, admin_bp):
        app.register_blueprint(bp)
