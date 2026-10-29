"""관리자(ADMIN) 대시보드·회원 목록·관제 도구 바로가기."""
import os
from urllib.parse import urlsplit
from datetime import timedelta

from flask import Blueprint, request
from sqlalchemy import func, or_

from ..core.errors import not_found
from ..core.logging import app_log
from flask import current_app

from ..core.permissions import ROLE_ADMIN, current_user, roles_required
from ..core.responses import ok
from ..extensions import db
from ..models import (AuthLoginFailure, Invoice, MembershipAccount, Payment, SecurityIncident, SupportTicket,
                      User)
from ..payments.routes import payment_dict
from ..membership.tiers import customer_rank, tier_name
from ..plans.routes import my_active_subscription
from ..support.routes import mask_email
from ..models.base import utcnow

bp = Blueprint("admin_dashboard", __name__, url_prefix="/api/admin")


@bp.get("/dashboard")
@roles_required(ROLE_ADMIN)
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
        "protection": {
            "active_blocks": _active_blocks(now),
            "locked_accounts": User.query.filter(User.locked_at.isnot(None), User.is_active.is_(True)).count(),
            "privilege_violations": _violations(),
        },
        "incidents": {
            "open": sum(c for _, c in severity_rows),
            "by_severity": {s: 0 for s in ("critical", "high", "medium", "low", "info")} | dict(severity_rows),
        },
    })


# ---------- 회원 목록 (ADMIN) ----------
# 목록에는 이메일을 가려서 보여주고, 상세를 열 때만 전체를 보여주며 열람 기록을 남긴다 (최소 노출).

@bp.get("/account-locks")
@roles_required(ROLE_ADMIN)
def account_locks():
    try:
        page = max(int(request.args.get("page", 1)), 1)
    except ValueError:
        page = 1
    query = User.query.filter(User.locked_at.isnot(None), User.is_active.is_(True))
    q = (request.args.get("q") or "").strip()[:50]
    if q:
        query = query.filter(or_(User.name.like(f"%{q}%"), User.email.like(f"%{q}%")))
    total, size = query.count(), 20
    rows = query.order_by(User.locked_at.desc(), User.id.desc()).offset((page - 1) * size).limit(size).all()
    return ok({"accounts": [{"id": u.id, "name": u.name, "email": mask_email(u.email), "role": u.role,
                             "locked_at": _iso(u.locked_at), "lock_reason": u.lock_reason} for u in rows],
               "page": page, "size": size, "total": total})

@bp.get("/customers")
@roles_required(ROLE_ADMIN)
def customers():
    q = (request.args.get("q") or "").strip()[:50]
    try:
        page = max(int(request.args.get("page", 1)), 1)
    except ValueError:
        page = 1
    size = 20
    query = User.query.filter_by(role="CUSTOMER")
    status = request.args.get("status")
    if status == "LOCKED":
        query = query.filter(User.locked_at.isnot(None), User.is_active.is_(True))
    elif status == "ACTIVE":
        query = query.filter(User.locked_at.is_(None), User.is_active.is_(True))
    elif status == "DEACTIVATED":
        query = query.filter(User.is_active.is_(False))
    if q:
        like = f"%{q}%"
        query = query.filter(or_(User.name.like(like), User.email.like(like)))
    total = query.count()
    rows = query.order_by(User.created_at.desc()).offset((page - 1) * size).limit(size).all()

    items = []
    for u in rows:
        sub = my_active_subscription(u.id)
        account = MembershipAccount.query.filter_by(user_id=u.id).first()
        items.append({
            "id": u.id, "name": u.name, "email": mask_email(u.email), "is_active": u.is_active,
            "status": _status(u), "locked_at": _iso(u.locked_at), "lock_reason": u.lock_reason,
            "login_failures_15m": _failures_15m(u.email),
            "created_at": _iso(u.created_at), "last_login_at": _iso(u.last_login_at),
            "plan": sub.plan.name if sub else None,
            "membership": tier_name(account.tier) if account else None,
            "unpaid_amount": _unpaid(u.id),
            "open_tickets": SupportTicket.query.filter(SupportTicket.user_id == u.id,
                                                       SupportTicket.status.in_(("OPEN", "IN_PROGRESS"))).count(),
        })
    return ok({"customers": items, "page": page, "size": size, "total": total})


@bp.get("/customers/<int:user_id>")
@roles_required(ROLE_ADMIN)
def customer_detail(user_id):
    u = db.session.get(User, user_id)
    if u is None or u.role != "CUSTOMER":
        raise not_found("회원을 찾을 수 없습니다.")
    app_log("admin.customer.viewed", admin_id=current_user().id, customer_id=u.id)  # 열람 기록
    sub = my_active_subscription(u.id)
    account = MembershipAccount.query.filter_by(user_id=u.id).first()
    invoices = Invoice.query.filter_by(user_id=u.id).order_by(Invoice.period.desc()).limit(6).all()
    tickets = SupportTicket.query.filter_by(user_id=u.id).order_by(SupportTicket.created_at.desc()).limit(10).all()
    payments = Payment.query.filter_by(user_id=u.id).order_by(Payment.id.desc()).limit(10).all()
    return ok({"customer": {
        "id": u.id, "name": u.name, "email": u.email, "is_active": u.is_active,
        "status": _status(u), "locked_at": _iso(u.locked_at), "lock_reason": u.lock_reason,
        "login_failures_15m": _failures_15m(u.email),
        "created_at": _iso(u.created_at), "last_login_at": _iso(u.last_login_at),
        "subscription": None if not sub else {"phone_number": sub.phone_number, "plan": sub.plan.to_dict(),
                                              "started_on": sub.started_on.isoformat()},
        "membership": None if not account else {"tier": tier_name(account.tier), "rank": customer_rank(account.tier.rank), "point_balance": account.point_balance},
        "unpaid_amount": _unpaid(u.id),
        "invoices": [i.to_dict() for i in invoices],
        "tickets": [{"id": t.id, "title": t.title, "status": t.status, "created_at": _iso(t.created_at)} for t in tickets],
        "payments": [payment_dict(p) for p in payments],
    }})


def _iso(d):
    return d.isoformat() + "Z" if d else None


def _active_blocks(now) -> int:
    from ..incidents.protection import _active_blocks_query
    return _active_blocks_query(now).count()


def _violations() -> int:
    from ..incidents.protection import privilege_violations
    return len(privilege_violations())


def _status(u) -> str:
    if not u.is_active:
        return "DEACTIVATED"
    return "LOCKED" if u.locked_at else "ACTIVE"


def _failures_15m(email: str) -> int:
    from ..auth.service import _key_hash
    return AuthLoginFailure.query.filter(
        AuthLoginFailure.key_type == "ACCOUNT", AuthLoginFailure.key_hash == _key_hash(email),
        AuthLoginFailure.created_at > utcnow() - timedelta(minutes=15)).count()


def _unpaid(user_id: int) -> int:
    return int(db.session.query(func.coalesce(func.sum(Invoice.amount), 0))
               .filter(Invoice.user_id == user_id, Invoice.status.in_(("UNPAID", "OVERDUE"))).scalar())


# ---------- 관제 도구 바로가기 ----------
# 주소는 환경변수로 받는다. 공용 PC에서는 관리 Nginx 경로(manage1/manage2.telecom.test)를 D·B와 확정해 넣는다.
# 로컬(APP_ENV=local)에서 값이 없으면 각 도구의 Docker 기본 주소를 보여준다.
MONITORING_TOOLS = [
    # key, 이름, 환경변수, 로컬 기본값, 설명
    ("wazuh", "Wazuh", "WAZUH_DASHBOARD_URL", "https://localhost", "호스트 보안 경보·에이전트 상태"),
    ("graylog", "Graylog", "GRAYLOG_URL", "http://localhost:9000", "중앙 로그 검색·이벤트"),
    ("grafana", "Grafana", "GRAFANA_URL", "http://localhost:3000", "보안·서비스 지표 대시보드"),
    ("zabbix", "Zabbix", "ZABBIX_URL", None, "서버·서비스 가용성"),
    ("n8n", "n8n", "N8N_EDITOR_URL", None, "인시던트 자동화 워크플로"),
]


def _safe_url(value):
    if not value:
        return None
    parts = urlsplit(value)
    return value if parts.scheme in ("http", "https") and parts.netloc else None  # javascript: 등 차단


@bp.get("/monitoring-links")
@roles_required(ROLE_ADMIN)
def monitoring_links():
    local = current_app.config.get("APP_ENV") == "local"
    items = []
    for key, name, env, local_default, desc in MONITORING_TOOLS:
        url = _safe_url(os.getenv(env)) or (local_default if local else None)
        if url or key in ("wazuh", "graylog", "grafana"):  # 주요 3종은 미설정이어도 자리를 보여준다
            items.append({"key": key, "name": name, "url": url, "description": desc, "env": env})
    return ok({"links": items, "grafana_embed_url": _grafana_embed_url(),
               "grafana_panel_url": _grafana_panel_url()})


def _grafana_panel_url():
    """관리자 대시보드에 띄울 Grafana 패널 하나 (GRAFANA_PANEL_URL, Share → Embed 의 d-solo 주소)."""
    url = _safe_url(os.getenv("GRAFANA_PANEL_URL"))
    if not url:
        return None
    sep = "&" if "?" in url else "?"
    for key, value in (("timezone", "Asia%2FSeoul"), ("refresh", "30s")):
        if f"{key}=" not in url:
            url += f"{sep}{key}={value}"
            sep = "&"
    return url


def _grafana_embed_url():
    """관리자 화면 안에 띄울 Grafana 대시보드 주소 (GRAFANA_EMBED_URL).

    Grafana 쪽에서 GF_SECURITY_ALLOW_EMBEDDING=true, 익명 보기(Viewer)가 켜져 있어야 화면에 보인다.
    kiosk(메뉴 숨김)·한국 시간·30초 새로고침이 빠져 있으면 붙여 준다.
    """
    url = _safe_url(os.getenv("GRAFANA_EMBED_URL"))
    if not url:
        return None
    sep = "&" if "?" in url else "?"
    for key, value in (("kiosk", ""), ("timezone", "Asia%2FSeoul"), ("refresh", "30s")):
        if f"{key}=" not in url and f"&{key}&" not in url and not url.endswith(f"&{key}"):
            url += f"{sep}{key}" + (f"={value}" if value else "")
            sep = "&"
    return url
