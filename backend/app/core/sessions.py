"""MySQL 공유 서버 세션 (통합 기준 7절, docs/contracts/auth-api.md).

- 쿠키: __Host-telecom_session, Secure / HttpOnly / SameSite=Lax / Path=/ / Domain 없음
- 유휴 30분, 절대 8시간. 로그아웃·비밀번호 변경·탈퇴 시 DB에서 폐기
- API Pod 메모리에는 아무것도 저장하지 않는다 → 어느 Pod로 요청이 가도 같은 결과
"""
import hashlib
import hmac
import secrets
from datetime import timedelta

from flask import current_app, g, request

from ..extensions import db
from ..models import AuthSession, User
from ..models.base import utcnow

TOUCH_INTERVAL = timedelta(seconds=60)  # last_seen_at 갱신 주기 (매 요청 쓰기 방지)


def token_hash(raw: str) -> str:
    return hashlib.sha256(raw.encode()).hexdigest()


def create_session(user: User):
    raw = secrets.token_urlsafe(32)  # 32바이트 난수
    now = utcnow()
    session = AuthSession(token_hash=token_hash(raw), user_id=user.id, csrf_token=secrets.token_urlsafe(32),
                          created_at=now, last_seen_at=now,
                          expires_at=now + timedelta(hours=current_app.config["SESSION_ABSOLUTE_HOURS"]))
    db.session.add(session)
    return raw, session


def set_session_cookie(response, raw: str):
    response.set_cookie(
        current_app.config["SESSION_COOKIE_NAME"], raw,
        max_age=current_app.config["SESSION_ABSOLUTE_HOURS"] * 3600,
        secure=True, httponly=True, samesite="Lax", path="/",
    )


def clear_session_cookie(response):
    response.delete_cookie(current_app.config["SESSION_COOKIE_NAME"], path="/", secure=True,
                           httponly=True, samesite="Lax")


def revoke_user_sessions(user_id: int):
    now = utcnow()
    AuthSession.query.filter(AuthSession.user_id == user_id, AuthSession.revoked_at.is_(None)) \
        .update({AuthSession.revoked_at: now}, synchronize_session=False)


def _valid(session: AuthSession, now) -> bool:
    if session.revoked_at is not None or session.expires_at <= now:
        return False
    idle = timedelta(minutes=current_app.config["SESSION_IDLE_MINUTES"])
    return session.last_seen_at + idle > now


def load_session():
    """요청마다 쿠키 → DB 세션 → 사용자. 실패하면 g.auth_session = None."""
    g.auth_session = None
    g.current_user = None
    raw = request.cookies.get(current_app.config["SESSION_COOKIE_NAME"])
    if not raw or len(raw) > 128:
        return
    session = AuthSession.query.filter_by(token_hash=token_hash(raw)).first()
    now = utcnow()
    if session is None or not _valid(session, now):
        return
    user = db.session.get(User, session.user_id)
    if user is None or not user.is_active:
        return
    if now - session.last_seen_at >= TOUCH_INTERVAL:
        session.last_seen_at = now
        db.session.commit()
    g.auth_session, g.current_user = session, user


def csrf_ok() -> bool:
    session = g.get("auth_session")
    given = request.headers.get("X-CSRF-Token", "")
    return bool(session and given and hmac.compare_digest(given, session.csrf_token))


def init_sessions(app):
    @app.before_request
    def _load():
        if request.path.startswith("/api/") and not request.path.startswith(("/api/health", "/api/internal")):
            load_session()
