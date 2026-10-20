"""보안 대시보드 업무 로직: IP 차단·화이트리스트·계정 잠금·권한 회수·작업 기록.

팀 결정 (2026-10-19)
  - 차단 위치: 실습과 같은 앱(L7) 차단. 방화벽 연동은 firewall.py 자리에 나중에 붙인다.
  - 토큰: INCIDENT_API_TOKEN 과 AUTOMATION_API_TOKEN 을 같은 값으로 시작 (config.py).
  - 화면: 처리자 열은 없음(기록은 security_audit_logs 에 남김), 해제 예정 시각은 관리자에게만.
자동화(n8n)는 차단·잠금·회수만 할 수 있고, 해제·권한 부여는 사람(관리자/CLI)만 한다.
"""
import hmac
import ipaddress
from datetime import timedelta

from flask import current_app, g, request

from ..core.errors import ApiError, validation_error
from ..core.logging import client_ip, security_event
from ..core.sessions import revoke_user_sessions
from ..extensions import db
from ..models import IpBlock, IpWhitelist, SecurityAuditLog, User
from ..models.base import utcnow
from .firewall import get_firewall

ROLE_ADMIN, ROLE_CUSTOMER = "ADMIN", "CUSTOMER"
MAX_REASON = 200


# ---------- 공통 ----------

def normalize_ip(value) -> str:
    try:
        return str(ipaddress.ip_address(str(value).strip()))
    except ValueError:
        raise validation_error({"ip": f"올바른 IP 주소가 아닙니다: {str(value)[:45]}"})


def clean_reason(value, default: str) -> str:
    text = value.strip() if isinstance(value, str) else ""
    return (text or default)[:MAX_REASON]


def audit(action: str, target_type: str, target, *, actor_type: str, actor_id=None, workflow=None,
          result="DONE", reason=None):
    db.session.add(SecurityAuditLog(actor_type=actor_type, actor_id=actor_id, workflow=workflow, action=action,
                                    target_type=target_type, target=str(target), result=result,
                                    reason=(reason or None) and reason[:MAX_REASON]))


def check_automation_token(config_key: str = "AUTOMATION_API_TOKEN"):
    """n8n 전용 토큰. 실습 노드를 그대로 쓸 수 있게 Authorization: Bearer 와 X-API-Key 둘 다 받는다."""
    expected = current_app.config.get(config_key) or ""
    if not expected:
        raise ApiError("INTEGRATION_DISABLED", f"{config_key} 가 설정되지 않았습니다.", 503)
    auth = request.headers.get("Authorization", "")
    given = auth[7:] if auth.startswith("Bearer ") else request.headers.get("X-API-Key", "")
    if not given or not hmac.compare_digest(given.encode(), expected.encode()):
        current_app.logger.warning("automation.unauthorized")
        raise ApiError("UNAUTHORIZED", "인증이 필요합니다.", 401)
    workflow = (request.headers.get("X-Workflow") or "").strip()[:64] or None
    g.automation_workflow = workflow
    return workflow


# ---------- 화이트리스트 ----------

def whitelist_networks():
    nets = []
    for row in IpWhitelist.query.all():
        try:
            nets.append(ipaddress.ip_network(row.cidr, strict=False))
        except ValueError:
            continue
    return nets


def is_whitelisted(ip: str) -> bool:
    addr = ipaddress.ip_address(ip)
    return any(addr.version == n.version and addr in n for n in whitelist_networks())


def add_whitelist(cidr_value, memo, admin):
    try:
        net = ipaddress.ip_network(str(cidr_value).strip(), strict=False)
    except ValueError:
        raise validation_error({"cidr": "IP 또는 CIDR(예: 192.168.50.0/24) 형식이 아닙니다."})
    cidr = str(net)
    if IpWhitelist.query.filter_by(cidr=cidr).first():
        raise ApiError("ALREADY_EXISTS", "이미 등록된 주소입니다.", 409)
    row = IpWhitelist(cidr=cidr, memo=(memo or "").strip()[:100] or None, created_by=admin.id)
    db.session.add(row)
    # 화이트리스트에 들어간 주소의 현재 차단은 바로 풀어 준다
    now = utcnow()
    for block in _active_blocks_query(now).all():
        addr = ipaddress.ip_address(block.ip)
        if addr.version == net.version and addr in net:
            _release(block, now, actor_type="ADMIN", actor_id=admin.id, reason="화이트리스트 등록")
    audit("whitelist.added", "ip", cidr, actor_type="ADMIN", actor_id=admin.id, reason=row.memo)
    db.session.commit()
    security_event("security.whitelist.changed", "info", "화이트리스트 추가", cidr=cidr, change="added")
    return row


def remove_whitelist(row, admin):
    cidr = row.cidr
    db.session.delete(row)
    audit("whitelist.removed", "ip", cidr, actor_type="ADMIN", actor_id=admin.id)
    db.session.commit()
    security_event("security.whitelist.changed", "info", "화이트리스트 삭제", cidr=cidr, change="removed")


# ---------- IP 차단 ----------

def _active_blocks_query(now):
    return IpBlock.query.filter(IpBlock.released_at.is_(None),
                                db.or_(IpBlock.expires_at.is_(None), IpBlock.expires_at > now))


def active_block(ip: str, now=None):
    return _active_blocks_query(now or utcnow()).filter(IpBlock.ip == ip).first()


def block_status(block: IpBlock, now) -> str:
    if block.released_at:
        return "RELEASED"
    if block.expires_at and block.expires_at <= now:
        return "EXPIRED"
    return "ACTIVE"


def block_ip(ip_value, reason, minutes, *, source, actor_id=None, workflow=None):
    """반환: (block 또는 None, 결과). 결과: CREATED / ALREADY / WHITELISTED / SELF"""
    ip = normalize_ip(ip_value)
    actor_type = "AUTOMATION" if source == "AUTOMATION" else "ADMIN"
    if is_whitelisted(ip):
        audit("ip.block", "ip", ip, actor_type=actor_type, actor_id=actor_id, workflow=workflow,
              result="SKIPPED", reason="화이트리스트")
        return None, "WHITELISTED"
    if source == "MANUAL" and ip == client_ip():  # 실습처럼 지금 접속한 내 IP는 제외 (관리 화면 잠김 방지)
        return None, "SELF"
    now = utcnow()
    existing = active_block(ip, now)
    if existing:  # 이미 차단된 IP (실습의 "이미 차단된 IP") → 멱등 처리
        audit("ip.block", "ip", ip, actor_type=actor_type, actor_id=actor_id, workflow=workflow,
              result="ALREADY", reason=reason)
        return existing, "ALREADY"
    block = IpBlock(ip=ip, reason=reason, source=source, workflow=workflow, created_by=actor_id, created_at=now,
                    expires_at=(now + timedelta(minutes=minutes)) if minutes else None)
    db.session.add(block)
    db.session.flush()
    fw = get_firewall().block(ip, reason, block.expires_at)  # 방화벽 연동 자리
    block.firewall_status, block.firewall_ref = fw.status, fw.ref
    audit("ip.block", "ip", ip, actor_type=actor_type, actor_id=actor_id, workflow=workflow, reason=reason)
    security_event("security.ip.blocked", "medium", "IP 차단", ip=ip, block_source=source, workflow=workflow,
                   minutes=minutes, firewall_status=fw.status)
    return block, "CREATED"


def _release(block, now, *, actor_type, actor_id, reason):
    block.released_at, block.released_by = now, actor_id
    fw = get_firewall().release(block.ip, block.firewall_ref)
    if block.firewall_status != "SKIPPED" or fw.status != "SKIPPED":
        block.firewall_status = fw.status
    audit("ip.release", "ip", block.ip, actor_type=actor_type, actor_id=actor_id, reason=reason)
    security_event("security.ip.released", "info", "IP 차단 해제", ip=block.ip, reason=reason)


def release_blocks(ids, admin):
    now = utcnow()
    count = 0
    for block in IpBlock.query.filter(IpBlock.id.in_(ids), IpBlock.released_at.is_(None)).all():
        _release(block, now, actor_type="ADMIN", actor_id=admin.id, reason="관리자 해제")
        count += 1
    db.session.commit()
    return count


def guard_blocked_ip():
    """before_request: 차단된 IP의 /api 요청을 403. 해제 예정 시각은 알려주지 않는다."""
    path = request.path
    if not path.startswith("/api/") or path.startswith(("/api/health", "/api/internal")):
        return None
    ip = client_ip()
    try:
        ipaddress.ip_address(ip)
    except ValueError:
        return None
    block = active_block(ip)
    if block is None or is_whitelisted(ip):
        return None
    block.hit_count += 1
    block.last_hit_at = utcnow()
    first_hit = block.hit_count == 1
    db.session.commit()
    if first_hit:  # 차단 1건당 첫 재접근만 이벤트 (로그 폭주 방지), 나머지는 hit_count 로 집계
        security_event("security.ip.block_hit", "medium", "차단된 IP 재접근", ip=ip, block_id=block.id, path=path)
    from ..core.responses import fail
    return fail("IP_BLOCKED", "보안 정책에 따라 접근이 차단되었습니다. 문제가 있으면 고객센터로 문의하세요.", 403)


# ---------- 계정 잠금 ----------

def lock_user(user: User, reason: str, *, actor_type, actor_id=None, workflow=None):
    if user.role != ROLE_CUSTOMER:
        raise ApiError("ADMIN_PROTECTED", "관리자 계정은 잠글 수 없습니다.", 409)
    if not user.is_active:
        raise ApiError("CONFLICT", "탈퇴한 회원입니다.", 409)
    if user.is_locked:
        audit("account.lock", "user", user.id, actor_type=actor_type, actor_id=actor_id, workflow=workflow,
              result="ALREADY", reason=reason)
        return "ALREADY"
    user.locked_at, user.lock_reason = utcnow(), reason
    revoke_user_sessions(user.id)  # 잠그는 즉시 로그인 상태도 끊는다
    audit("account.lock", "user", user.id, actor_type=actor_type, actor_id=actor_id, workflow=workflow, reason=reason)
    security_event("auth.account.locked", "medium", "계정 잠금", target_user_id=user.id,
                   lock_source=actor_type, workflow=workflow)
    return "CREATED"


def unlock_user(user: User, admin):
    if not user.is_locked:
        return "ALREADY"
    user.locked_at, user.lock_reason = None, None
    audit("account.unlock", "user", user.id, actor_type="ADMIN", actor_id=admin.id)
    security_event("auth.account.unlocked", "info", "계정 잠금 해제", target_user_id=user.id)
    return "DONE"


def deactivate_user(user: User, admin, reason):
    if user.role != ROLE_CUSTOMER:
        raise ApiError("ADMIN_PROTECTED", "관리자 계정은 탈퇴 처리할 수 없습니다.", 409)
    if not user.is_active:
        raise ApiError("CONFLICT", "이미 탈퇴한 회원입니다.", 409)
    user.is_active = False  # 기록 보존을 위해 삭제하지 않는다 (실습의 '삭제'와 다름)
    revoke_user_sessions(user.id)
    audit("account.deactivate", "user", user.id, actor_type="ADMIN", actor_id=admin.id, reason=reason)
    security_event("auth.account.deactivated", "info", "관리자 탈퇴 처리", target_user_id=user.id)


# ---------- 권한 점검·회수 ----------

def allowlist():
    return current_app.config.get("ADMIN_ALLOWLIST") or []


def privilege_violations():
    allowed = allowlist()
    if not allowed:
        return []
    return [u for u in User.query.filter_by(role=ROLE_ADMIN, is_active=True).all() if u.email not in allowed]


def revoke_admin(user: User, reason: str, *, actor_type, actor_id=None, workflow=None):
    if user.role != ROLE_ADMIN:
        raise ApiError("NOT_ADMIN", "관리자 계정이 아닙니다.", 409)
    if actor_id is not None and user.id == actor_id:
        raise ApiError("SELF_REVOKE", "본인 권한은 회수할 수 없습니다.", 409)
    remaining = User.query.filter(User.role == ROLE_ADMIN, User.is_active.is_(True), User.id != user.id).count()
    if remaining == 0:
        raise ApiError("LAST_ADMIN", "마지막 관리자는 회수할 수 없습니다.", 409)
    user.role = ROLE_CUSTOMER
    revoke_user_sessions(user.id)  # 권한 변경 → 세션 폐기
    audit("role.revoke", "user", user.id, actor_type=actor_type, actor_id=actor_id, workflow=workflow, reason=reason)
    security_event("auth.role.revoked", "high", "관리자 권한 회수", target_user_id=user.id,
                   revoke_source=actor_type, workflow=workflow)
