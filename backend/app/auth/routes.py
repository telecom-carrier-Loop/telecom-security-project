"""인증 API (docs/contracts/auth-api.md)

POST /api/auth/register, /login, /logout · GET /api/auth/me
+ 프로필: PATCH /api/auth/me, POST /api/auth/password, POST /api/auth/deactivate
CSRF 토큰은 로그인 응답과 GET /api/auth/me 의 data.csrf_token 으로 받고, 상태 변경 요청에 X-CSRF-Token 헤더로 보낸다.
"""
from flask import Blueprint, g

from ..core.permissions import current_user, json_and_origin_required, login_required
from ..core.responses import ok
from ..core.sessions import clear_session_cookie, create_session, set_session_cookie
from ..core.validation import body
from ..extensions import db
from ..models.base import utcnow
from . import service

bp = Blueprint("auth", __name__, url_prefix="/api/auth")


@bp.post("/register")
@json_and_origin_required
def register():
    user = service.register(body())
    return ok({"user": user.to_public()}, 201)


@bp.post("/login")
@json_and_origin_required
def login():
    data = body()
    user = service.authenticate(data.get("email"), data.get("password"))
    raw, session = create_session(user)
    db.session.commit()
    resp, status = ok({"user": user.to_profile(), "csrf_token": session.csrf_token})
    set_session_cookie(resp, raw)  # 토큰은 쿠키로만 전달, 본문에는 넣지 않음
    return resp, status


@bp.post("/logout")
@login_required
def logout():
    g.auth_session.revoked_at = utcnow()  # DB 세션 폐기 → 다른 Pod에서도 즉시 무효
    db.session.commit()
    resp, status = ok({"logged_out": True})
    clear_session_cookie(resp)
    return resp, status


@bp.get("/me")
@login_required
def me():
    return ok({"user": current_user().to_profile(), "csrf_token": g.auth_session.csrf_token})


@bp.patch("/me")
@login_required
def update_me():
    return ok({"user": service.update_profile(current_user(), body()).to_profile()})


@bp.post("/password")
@login_required
def change_password():
    service.change_password(current_user(), body())
    resp, status = ok({"changed": True, "relogin_required": True})
    clear_session_cookie(resp)
    return resp, status


@bp.post("/deactivate")
@login_required
def deactivate():
    service.deactivate(current_user(), body())
    resp, status = ok({"deactivated": True})
    clear_session_cookie(resp)
    return resp, status
