"""관리자 대시보드. 고객 개인정보 목록이 아니라 '처리할 일'의 숫자만 보여준다."""
from datetime import timedelta

from flask import Blueprint
from sqlalchemy import func

from ..core.permissions import ADMIN_ROLES, roles_required
from ..core.responses import ok
from ..extensions import db
from ..models import AuthLoginFailure, Invoice, SecurityIncident, SupportTicket, User
from ..models.base import utcnow

bp = Blueprint("admin_dashboard", __name__, url_prefix="/api/admin")


@bp.get("/dashboard")
@roles_required(*ADMIN_ROLES)
def dashboard():
    now = utcnow()
    unpaid_count, unpaid_amount = db.session.query(
        func.count(Invoice.id), func.coalesce(func.sum(Invoice.amount), 0)
    ).filter(Invoice.status.in_(("UNPAID", "OVERDUE"))).one()

    severity_rows = (db.session.query(SecurityIncident.severity, func.count(SecurityIncident.id))
                     .filter(SecurityIncident.status.in_(("OPEN", "INVESTIGATING")))
                     .group_by(SecurityIncident.severity).all())
    open_tickets = (SupportTicket.query.filter(SupportTicket.status.in_(("OPEN", "IN_PROGRESS")))
                    .order_by(SupportTicket.created_at).limit(5).all())

    return ok({
        "customers": {
            "active": User.query.filter_by(role="CUSTOMER", is_active=True).count(),
            "new_7d": User.query.filter(User.role == "CUSTOMER",
                                        User.created_at >= now - timedelta(days=7)).count(),
            # 최근 15분 계정별 로그인 실패 (존재하지 않는 계정 포함, 개인정보 없이 건수만)
            "login_failures_15m": AuthLoginFailure.query.filter(
                AuthLoginFailure.key_type == "ACCOUNT", AuthLoginFailure.created_at > now - timedelta(minutes=15)).count(),
        },
        "support": {
            "waiting": SupportTicket.query.filter(
                SupportTicket.status.in_(("OPEN", "IN_PROGRESS"))).count(),
            "oldest": [{"id": t.id, "title": t.title, "status": t.status,
                        "created_at": t.created_at.isoformat() + "Z"} for t in open_tickets],
        },
        "billing": {"unpaid_count": unpaid_count, "unpaid_amount": int(unpaid_amount)},
        "incidents": {
            "open": sum(c for _, c in severity_rows),
            "by_severity": {s: 0 for s in ("critical", "high", "medium", "low", "info")} | dict(severity_rows),
        },
    })
