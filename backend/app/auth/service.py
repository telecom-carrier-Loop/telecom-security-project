import hashlib
import re
from datetime import timedelta

from flask import current_app
from sqlalchemy import func

from ..core.errors import ApiError, validation_error
from ..core.logging import app_log, client_ip, security_event
from ..core.sessions import revoke_user_sessions
from ..extensions import db
from ..models import AuthLoginFailure, User
from ..models.base import utcnow

EMAIL_RE = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")


def _password_error(password: str):
    if not isinstance(password, str) or not 8 <= len(password) <= 128 \
            or not re.search(r"[A-Za-z]", password) or not re.search(r"\d", password):
        return "비밀번호는 영문과 숫자를 포함해 8~128자여야 합니다."
    return None


def _name_error(name: str):
    return None if 1 <= len(name) <= 50 else "이름을 1~50자로 입력하세요."


def _norm_email(value) -> str:
    return value.strip().lower() if isinstance(value, str) else ""


def _key_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def account_hash(email: str) -> str:
    """로그·자동화에서 계정을 가리키는 값 (이메일 원문 대신)."""
    return _key_hash(_norm_email(email))


def register(data: dict) -> User:
    email, password = _norm_email(data.get("email")), data.get("password") or ""
    name = data.get("name").strip() if isinstance(data.get("name"), str) else ""
    errors = {}
    if not EMAIL_RE.match(email) or len(email) > 255:
        errors["email"] = "올바른 이메일 형식이 아닙니다."
    if _password_error(password):
        errors["password"] = _password_error(password)
    if _name_error(name):
        errors["name"] = _name_error(name)
    if errors:
        raise validation_error(errors)
    if User.query.filter_by(email=email).first():
        raise ApiError("EMAIL_TAKEN", "이미 가입된 이메일입니다.", 409)

    # 본문에 role 이 있어도 무시 — 공개 가입은 항상 CUSTOMER (관리 계정은 비공개 프로비저닝)
    user = User(email=email, name=name, role="CUSTOMER", password_changed_at=utcnow())
    user.set_password(password)
    db.session.add(user)
    # L∞P+ 멤버십은 선택 가입 → 회원가입만으로는 멤버십 계정을 만들지 않는다
    db.session.commit()
    return user


# ---------- 로그인 실패 제한: 계정별 15분 5회, IP별 15분 20회 (공유 DB) ----------

def _recent_failures(key_type: str, key: str, since):
    q = db.session.query(func.count(AuthLoginFailure.id), func.min(AuthLoginFailure.created_at)) \
        .filter(AuthLoginFailure.key_type == key_type, AuthLoginFailure.key_hash == key,
                AuthLoginFailure.created_at > since)
    return q.one()


def _check_rate_limit(account_key: str, ip_key: str, now):
    window = timedelta(minutes=current_app.config["LOGIN_WINDOW_MINUTES"])
    for key_type, key, limit in (("ACCOUNT", account_key, current_app.config["LOGIN_MAX_PER_ACCOUNT"]),
                                 ("IP", ip_key, current_app.config["LOGIN_MAX_PER_IP"])):
        count, oldest = _recent_failures(key_type, key, now - window)
        if count >= limit:
            retry_after = max(int((oldest + window - now).total_seconds()) + 1, 1)
            security_event("auth.rate_limited", "medium", "로그인 시도 제한 초과",
                           limit_type=key_type.lower(), retry_after=retry_after,
                           src_ip=client_ip(), account_hash=account_key)
            raise ApiError("TOO_MANY_ATTEMPTS", "로그인 시도가 많습니다. 잠시 후 다시 시도하세요.", 429,
                           headers={"Retry-After": str(retry_after)})


def authenticate(email_value, password) -> User:
    email = _norm_email(email_value)
    account_key, ip_key = _key_hash(email), _key_hash(client_ip())
    now = utcnow()
    _check_rate_limit(account_key, ip_key, now)

    user = User.query.filter_by(email=email).first() if email else None
    if not user or not user.is_active or not user.check_password(password if isinstance(password, str) else ""):
        # 계정 유무와 관계없이 같은 방식으로 기록·응답한다 (계정 열거 방지)
        db.session.add_all([AuthLoginFailure(key_type="ACCOUNT", key_hash=account_key, created_at=now),
                            AuthLoginFailure(key_type="IP", key_hash=ip_key, created_at=now)])
        db.session.commit()
        # src_ip: 4-ip 차단봇이 출발지별로 집계, account_hash: 8-계정잠금봇이 계정별로 집계
        # (이메일 원문은 남기지 않는다. account_hash = SHA-256(소문자 이메일), 없는 계정도 같은 방식)
        security_event("auth.login.failed", "low", "로그인 실패", reason="invalid_credentials",
                       src_ip=client_ip(), account_hash=account_key)
        raise ApiError("INVALID_CREDENTIALS", "이메일 또는 비밀번호가 올바르지 않습니다.", 401)

    if user.is_locked:
        security_event("auth.account.login_locked", "medium", "잠긴 계정 로그인 시도", target_user_id=user.id,
                       src_ip=client_ip(), account_hash=account_key)
        raise ApiError("ACCOUNT_LOCKED", "보안 정책에 따라 잠긴 계정입니다. 고객센터로 문의하세요.", 403)

    # 이번 로그인 직전 실패 횟수(지난 로그인 이후)를 남기고, 계정 카운터만 비운다 (IP 카운터는 유지)
    since = user.last_login_at or user.created_at
    user.failed_attempts_before_login = AuthLoginFailure.query.filter(
        AuthLoginFailure.key_type == "ACCOUNT", AuthLoginFailure.key_hash == account_key,
        AuthLoginFailure.created_at > since).count()
    AuthLoginFailure.query.filter_by(key_type="ACCOUNT", key_hash=account_key).delete()
    user.previous_login_at, user.last_login_at = user.last_login_at, now
    return user  # 세션 생성과 함께 routes 에서 commit


def update_profile(user: User, data: dict) -> User:
    # 이메일·역할은 여기서 바꿀 수 없다 (허용 필드만 꺼내 쓴다)
    name = data.get("name").strip() if isinstance(data.get("name"), str) else ""
    if _name_error(name):
        raise validation_error({"name": _name_error(name)})
    user.name = name
    db.session.commit()
    return user


def change_password(user: User, data: dict) -> None:
    current, new = data.get("current_password") or "", data.get("new_password") or ""
    if not user.check_password(current):
        raise validation_error({"current_password": "현재 비밀번호가 맞지 않습니다."})
    error = _password_error(new) or ("현재 비밀번호와 다른 비밀번호를 입력하세요." if current == new else None)
    if error:
        raise validation_error({"new_password": error})
    user.set_password(new)
    user.password_changed_at = utcnow()
    revoke_user_sessions(user.id)  # 비밀번호 변경 → 이 사용자의 모든 세션 폐기 (다시 로그인)
    db.session.commit()
    app_log("auth.password.changed", user_id=user.id)


def deactivate(user: User, data: dict) -> None:
    if user.role != "CUSTOMER":
        raise ApiError("FORBIDDEN", "관리자 계정은 이 화면에서 해지할 수 없습니다.", 403)
    if not user.check_password(data.get("password") or ""):
        raise validation_error({"password": "비밀번호가 맞지 않습니다."})
    user.is_active = False  # 기록 보존을 위해 삭제하지 않고 비활성화
    revoke_user_sessions(user.id)
    db.session.commit()
    app_log("auth.account.deactivated", user_id=user.id)
