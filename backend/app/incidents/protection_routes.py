"""보안 대시보드 API.

관리자(세션 + CSRF, ADMIN)
  GET    /api/admin/ip-blocks?q=&status=active|all&page=   차단 IP 목록 (해제 예정 시각 포함 — 관리자만)
  POST   /api/admin/ip-blocks                             {ips: "a, b" 또는 [..], reason, minutes(null=영구)}
  POST   /api/admin/ip-blocks/release                     {ids: [..]} 선택 해제
  GET    /api/admin/ip-whitelist                          화이트리스트
  POST   /api/admin/ip-whitelist                          {cidr, memo}
  DELETE /api/admin/ip-whitelist/{id}
  POST   /api/admin/customers/{id}/lock|unlock|deactivate {reason}
  POST   /api/admin/customers/bulk                        {action: lock|unlock, ids: [..], reason}
  GET    /api/admin/privileges                            관리자 목록 + 허용목록 위반
  POST   /api/admin/users/{id}/revoke-admin               {reason}
  GET    /api/admin/automation-status                     워크플로별 최근 처리

자동화(n8n, AUTOMATION_API_TOKEN — Authorization: Bearer 또는 X-API-Key, 선택 헤더 X-Workflow)
  POST   /api/internal/ip-blocks                          {ip 또는 src_ip, reason, minutes}
  POST   /api/internal/account-locks                      {account_hash 또는 email, reason}
  GET    /api/internal/privilege-violations               허용목록 밖 관리자
  POST   /api/internal/role-revocations                   {email, reason} (허용목록 밖 관리자만 회수)
"""
from collections import defaultdict
from datetime import timedelta

from flask import Blueprint, current_app, request

from ..core.errors import ApiError, not_found, validation_error
from ..core.logging import security_event
from ..core.permissions import ROLE_ADMIN, current_user, roles_required
from ..core.responses import ok
from ..core.validation import body
from ..extensions import db
from ..models import IpBlock, IpWhitelist, SecurityAuditLog, User
from ..models.base import utcnow
from . import protection as svc

bp = Blueprint("protection", __name__, url_prefix="/api")

MINUTE_CHOICES = (30, 60, 360, 1440, 10080)  # 30분 · 1시간 · 6시간 · 1일 · 7일, null = 영구
KNOWN_WORKFLOWS = [
    # key(X-Workflow 헤더 값), 이름, n8n Webhook, 부르는 앱 API
    ("4-ip-block", "4-ip 차단봇", "/webhook/ip-block", "POST /api/internal/ip-blocks"),
    ("9-snort-ip-block", "9-S11 Snort IP 차단봇", "/webhook/snort-ip-block", "POST /api/internal/ip-blocks"),
    ("8-login-bruteforce", "8-브루트포스 계정잠금봇", "/webhook/login-bruteforce", "POST /api/internal/account-locks"),
    ("7-wazuh-alert", "7-Wazuh 경보봇", "/webhook/wazuh-alert", "POST /api/internal/incident-events"),
    ("6-incident", "6-인시던트 리포트봇", "/webhook/incident", "POST /api/internal/incident-events"),
    ("5-security-alert", "5-복합 공격 경보봇", "/webhook/security-alert", "POST /api/internal/incident-events"),
    ("1-priv-guard", "1-자동 회수 봇", "/webhook/priv-guard",
     "GET /api/internal/privilege-violations · POST /api/internal/role-revocations"),
]
ACTION_LABEL = {"ip.block": "IP 차단", "account.lock": "계정 잠금", "role.revoke": "권한 회수",
                "incident.ingest": "인시던트 수신", "privilege.check": "권한 점검"}


def _iso(d):
    return d.isoformat() + "Z" if d else None


def _page():
    try:
        return max(int(request.args.get("page", 1)), 1)
    except ValueError:
        return 1


def _minutes(value, default):
    if value is None:
        return None if default is None else default
    if not isinstance(value, int) or isinstance(value, bool) or not 1 <= value <= 60 * 24 * 30:
        raise validation_error({"minutes": "차단 시간(분)은 1~43200 사이 정수이거나 null(영구)이어야 합니다."})
    return value


def block_dict(b: IpBlock, now):
    return {"id": b.id, "ip": b.ip, "reason": b.reason, "source": b.source, "workflow": b.workflow,
            "created_at": _iso(b.created_at), "expires_at": _iso(b.expires_at),  # 관리자 API에서만 내려준다
            "released_at": _iso(b.released_at), "status": svc.block_status(b, now),
            "hit_count": b.hit_count, "last_hit_at": _iso(b.last_hit_at), "firewall_status": b.firewall_status}


# ================= 관리자 =================

@bp.get("/admin/ip-blocks")
@roles_required(ROLE_ADMIN)
def list_blocks():
    now, page, size = utcnow(), _page(), 20
    query = IpBlock.query
    if request.args.get("status", "active") == "active":
        query = svc._active_blocks_query(now)
    q = (request.args.get("q") or "").strip()[:50]
    if q:
        query = query.filter(db.or_(IpBlock.ip.like(f"%{q}%"), IpBlock.reason.like(f"%{q}%"),
                                    IpBlock.workflow.like(f"%{q}%")))
    total = query.count()
    rows = query.order_by(IpBlock.created_at.desc()).offset((page - 1) * size).limit(size).all()
    return ok({"blocks": [block_dict(b, now) for b in rows], "page": page, "size": size, "total": total,
               "minute_choices": MINUTE_CHOICES, "my_ip": svc.client_ip()})


@bp.post("/admin/ip-blocks")
@roles_required(ROLE_ADMIN)
def add_blocks():
    data, admin = body(), current_user()
    raw = data.get("ips")
    items = raw if isinstance(raw, list) else str(raw or "").replace("\n", ",").split(",")
    ips = [str(i).strip() for i in items if str(i).strip()][:50]
    if not ips:
        raise validation_error({"ips": "차단할 IP를 입력하세요."})
    minutes = _minutes(data.get("minutes"), None) if "minutes" in data else current_app.config["IP_BLOCK_DEFAULT_MINUTES"]
    reason = svc.clean_reason(data.get("reason"), "관리자 수동 차단")
    results = []
    for value in ips:
        block, result = svc.block_ip(value, reason, minutes, source="MANUAL", actor_id=admin.id)
        results.append({"ip": svc.normalize_ip(value), "result": result})
    db.session.commit()
    return ok({"results": results}, 201)


@bp.post("/admin/ip-blocks/release")
@roles_required(ROLE_ADMIN)
def release_blocks():
    ids = [i for i in (body().get("ids") or []) if isinstance(i, int) and not isinstance(i, bool)]
    if not ids:
        raise validation_error({"ids": "해제할 항목을 선택하세요."})
    return ok({"released": svc.release_blocks(ids, current_user())})


@bp.get("/admin/ip-whitelist")
@roles_required(ROLE_ADMIN)
def list_whitelist():
    rows = IpWhitelist.query.order_by(IpWhitelist.id).all()
    return ok({"whitelist": [{"id": r.id, "cidr": r.cidr, "memo": r.memo, "created_at": _iso(r.created_at)}
                             for r in rows], "my_ip": svc.client_ip()})


@bp.post("/admin/ip-whitelist")
@roles_required(ROLE_ADMIN)
def add_whitelist():
    data = body()
    row = svc.add_whitelist(data.get("cidr"), data.get("memo"), current_user())
    return ok({"entry": {"id": row.id, "cidr": row.cidr, "memo": row.memo}}, 201)


@bp.delete("/admin/ip-whitelist/<int:entry_id>")
@roles_required(ROLE_ADMIN)
def delete_whitelist(entry_id):
    row = db.session.get(IpWhitelist, entry_id)
    if row is None:
        raise not_found("화이트리스트 항목을 찾을 수 없습니다.")
    svc.remove_whitelist(row, current_user())
    return ok({"deleted": True})


def _customer(user_id):
    user = db.session.get(User, user_id)
    if user is None or user.role != "CUSTOMER":
        raise not_found("회원을 찾을 수 없습니다.")
    return user


@bp.post("/admin/customers/<int:user_id>/lock")
@roles_required(ROLE_ADMIN)
def lock_customer(user_id):
    result = svc.lock_user(_customer(user_id), svc.clean_reason(body().get("reason"), "관리자 잠금"),
                           actor_type="ADMIN", actor_id=current_user().id)
    db.session.commit()
    return ok({"result": result})


@bp.post("/admin/customers/<int:user_id>/unlock")
@roles_required(ROLE_ADMIN)
def unlock_customer(user_id):
    result = svc.unlock_user(_customer(user_id), current_user())
    db.session.commit()
    return ok({"result": result})


@bp.post("/admin/customers/<int:user_id>/deactivate")
@roles_required(ROLE_ADMIN)
def deactivate_customer(user_id):
    svc.deactivate_user(_customer(user_id), current_user(), svc.clean_reason(body().get("reason"), "관리자 탈퇴 처리"))
    db.session.commit()
    return ok({"deactivated": True})


@bp.post("/admin/customers/bulk")
@roles_required(ROLE_ADMIN)
def bulk_customers():
    data, admin = body(), current_user()
    action = data.get("action")
    ids = [i for i in (data.get("ids") or []) if isinstance(i, int) and not isinstance(i, bool)][:100]
    if action not in ("lock", "unlock") or not ids:
        raise validation_error({"action": "action(lock/unlock)과 ids 가 필요합니다."})
    reason = svc.clean_reason(data.get("reason"), "관리자 일괄 잠금")
    done = 0
    for user in User.query.filter(User.id.in_(ids), User.role == "CUSTOMER", User.is_active.is_(True)).all():
        result = (svc.lock_user(user, reason, actor_type="ADMIN", actor_id=admin.id) if action == "lock"
                  else svc.unlock_user(user, admin))
        done += result in ("CREATED", "DONE")
    db.session.commit()
    return ok({"changed": done})


@bp.get("/admin/privileges")
@roles_required(ROLE_ADMIN)
def privileges():
    me, allowed = current_user(), svc.allowlist()
    admins = User.query.filter_by(role=ROLE_ADMIN, is_active=True).order_by(User.id).all()
    return ok({
        "allowlist_configured": bool(allowed),
        "allowlist_size": len(allowed),
        "admins": [{"id": u.id, "name": u.name, "email": u.email, "is_self": u.id == me.id,
                    "in_allowlist": (u.email in allowed) if allowed else None,
                    "last_login_at": _iso(u.last_login_at), "created_at": _iso(u.created_at)} for u in admins],
        "violations": len(svc.privilege_violations()),
    })


@bp.post("/admin/users/<int:user_id>/revoke-admin")
@roles_required(ROLE_ADMIN)
def revoke_admin(user_id):
    user = db.session.get(User, user_id)
    if user is None:
        raise not_found("사용자를 찾을 수 없습니다.")
    admin = current_user()
    svc.revoke_admin(user, svc.clean_reason(body().get("reason"), "관리자 수동 회수"),
                     actor_type="ADMIN", actor_id=admin.id)
    db.session.commit()
    return ok({"revoked": True})


@bp.get("/admin/automation-status")
@roles_required(ROLE_ADMIN)
def automation_status():
    now = utcnow()
    today = now.replace(hour=0, minute=0, second=0, microsecond=0)
    since = now - timedelta(days=7)
    rows = (SecurityAuditLog.query.filter(SecurityAuditLog.actor_type == "AUTOMATION",
                                          SecurityAuditLog.created_at >= since)
            .order_by(SecurityAuditLog.created_at.desc()).all())
    stats = defaultdict(lambda: {"last_at": None, "today": 0, "week": 0, "by_action": defaultdict(int)})
    for r in rows:
        s = stats[r.workflow or "unknown"]
        s["last_at"] = s["last_at"] or r.created_at
        s["week"] += 1
        if r.created_at >= today:
            s["today"] += 1
        s["by_action"][ACTION_LABEL.get(r.action, r.action)] += 1
    known = {k for k, *_ in KNOWN_WORKFLOWS}
    items = []
    for key, name, webhook, api in KNOWN_WORKFLOWS + [(k, k, None, None) for k in stats if k not in known]:
        s = stats.get(key)
        items.append({"key": key, "name": name, "webhook": webhook, "api": api,
                      "last_at": _iso(s["last_at"]) if s else None, "today": s["today"] if s else 0,
                      "week": s["week"] if s else 0, "by_action": dict(s["by_action"]) if s else {}})
    return ok({"workflows": items})


# ================= 자동화 (n8n) =================

@bp.post("/internal/ip-blocks")
def internal_block():
    workflow = svc.check_automation_token()
    data = body()
    ip = data.get("ip") or data.get("src_ip")  # 실습 페이로드(src_ip)도 받는다
    if not ip:
        raise validation_error({"ip": "ip 또는 src_ip 가 필요합니다."})
    minutes = _minutes(data.get("minutes"), current_app.config["IP_BLOCK_DEFAULT_MINUTES"])
    reason = svc.clean_reason(data.get("reason"), "자동화 차단")
    block, result = svc.block_ip(ip, reason, minutes, source="AUTOMATION", workflow=workflow)
    db.session.commit()
    # 해제 예정 시각은 돌려주지 않는다 (관리자 화면에서만 확인)
    return ok({"ip": svc.normalize_ip(ip), "blocked": result in ("CREATED", "ALREADY"), "result": result},
              201 if result == "CREATED" else 200)


@bp.post("/internal/account-locks")
def internal_lock():
    workflow = svc.check_automation_token()
    data = body()
    email = (data.get("email") or data.get("username") or "").strip().lower()
    acc_hash = str(data.get("account_hash") or "").strip().lower()
    if not email and not acc_hash:
        raise validation_error({"account_hash": "account_hash(로그인 실패 로그의 값) 또는 email 이 필요합니다."})
    if acc_hash and (len(acc_hash) != 64 or any(c not in "0123456789abcdef" for c in acc_hash)):
        raise validation_error({"account_hash": "SHA-256 16진수 64자여야 합니다."})
    if email:
        user = User.query.filter_by(email=email).first()
    else:
        from ..auth.service import account_hash
        # 계정 수가 많지 않은 실습 규모 기준. 커지면 users 에 email_hash 컬럼(인덱스)을 두면 된다
        user = next((u for u in User.query.filter_by(is_active=True).all() if account_hash(u.email) == acc_hash), None)
    target_label = email or f"hash:{acc_hash[:12]}"
    reason = svc.clean_reason(data.get("reason"), "브루트포스 자동 잠금")
    if user is None or not user.is_active:
        svc.audit("account.lock", "user", target_label, actor_type="AUTOMATION", workflow=workflow,
                  result="SKIPPED", reason="계정 없음")
        db.session.commit()
        return ok({"locked": False, "result": "NOT_FOUND"})
    if user.role != "CUSTOMER":  # 자동화가 관리자를 잠그면 관리 화면이 막힌다 → 인시던트로만 처리
        svc.audit("account.lock", "user", user.id, actor_type="AUTOMATION", workflow=workflow,
                  result="SKIPPED", reason="관리자 보호")
        db.session.commit()
        return ok({"locked": False, "result": "ADMIN_PROTECTED"})
    result = svc.lock_user(user, reason, actor_type="AUTOMATION", workflow=workflow)
    db.session.commit()
    return ok({"locked": True, "result": result}, 201 if result == "CREATED" else 200)


@bp.get("/internal/privilege-violations")
def internal_violations():
    workflow = svc.check_automation_token()
    if not svc.allowlist():
        return ok({"allowlist_configured": False, "violations": []})
    found = svc.privilege_violations()
    for u in found:
        security_event("auth.privilege.violation", "high", "허용목록 밖 관리자", target_user_id=u.id, workflow=workflow)
    svc.audit("privilege.check", "user", f"{len(found)}건", actor_type="AUTOMATION", workflow=workflow)
    db.session.commit()
    return ok({"allowlist_configured": True,
               "violations": [{"id": u.id, "email": u.email, "name": u.name} for u in found]})


@bp.post("/internal/role-revocations")
def internal_revoke():
    workflow = svc.check_automation_token()
    data = body()
    email = (data.get("email") or "").strip().lower()
    if not email:
        raise validation_error({"email": "email 이 필요합니다."})
    if not svc.allowlist():
        return ok({"revoked": False, "result": "ALLOWLIST_NOT_SET"})
    user = User.query.filter_by(email=email).first()
    if user is None or user.role != ROLE_ADMIN:
        return ok({"revoked": False, "result": "NOT_ADMIN"})
    if email in svc.allowlist():  # 자동화는 허용목록 밖 관리자만 회수할 수 있다
        return ok({"revoked": False, "result": "IN_ALLOWLIST"})
    try:
        svc.revoke_admin(user, svc.clean_reason(data.get("reason"), "허용목록 밖 관리자 자동 회수"),
                         actor_type="AUTOMATION", workflow=workflow)
    except ApiError as err:
        return ok({"revoked": False, "result": err.code})
    db.session.commit()
    return ok({"revoked": True, "result": "REVOKED"}, 201)
