"""B(인프라)가 Readiness/Liveness Probe에 쓰는 API."""
from flask import Blueprint, current_app
from sqlalchemy import text

from ..core.responses import fail, ok
from ..extensions import db

bp = Blueprint("health", __name__, url_prefix="/api")


@bp.get("/health/live")
def live():
    # 프로세스가 살아 있는지만 본다. DB 장애로 Pod가 재시작되지 않도록 DB는 확인하지 않음.
    return ok({"status": "ok"})


@bp.get("/health/ready")
def ready():
    # 트래픽을 받아도 되는지: DB 연결까지 확인
    try:
        db.session.execute(text("SELECT 1"))
    except Exception:
        current_app.logger.warning("readiness_db_failed")
        return fail("NOT_READY", "데이터베이스에 연결할 수 없습니다.", 503)
    return ok({"status": "ok", "database": "ok"})


@bp.get("/version")
def version():
    return ok({"version": current_app.config["APP_VERSION"]})
