"""인증·권한. 사용자는 항상 서버 세션에서 꺼낸다 (요청에 들어온 user_id는 믿지 않음).

401 = 로그인 없음, 403 = 역할 거부·CSRF 실패, 404 = 남의 객체 (통합 기준 7절)

역할: CUSTOMER / ADMIN
  팀 결정으로 상담 관리자(SUPPORT_ADMIN)와 보안 관리자(SECURITY_ADMIN)를 ADMIN 하나로 통합했다.
  (integration-baseline 7절의 3역할 구성과 다르므로 계약 문서 갱신 필요)
"""
from functools import wraps
from urllib.parse import urlsplit

from flask import g, request

from .errors import ApiError
from .logging import security_event
from .sessions import csrf_ok

ROLE_CUSTOMER = "CUSTOMER"
ROLE_ADMIN = "ADMIN"
ADMIN_ROLES = (ROLE_ADMIN,)
SAFE_METHODS = ("GET", "HEAD", "OPTIONS")


def current_user():
    user = g.get("current_user")
    if user is None:
        raise ApiError("UNAUTHORIZED", "인증이 필요합니다.", 401)
    return user


def _require_session():
    user = current_user()
    if request.method not in SAFE_METHODS and not csrf_ok():
        raise ApiError("CSRF_FAILED", "보안 토큰이 없거나 맞지 않습니다. 새로고침 후 다시 시도하세요.", 403)
    return user


def login_required(fn):
    @wraps(fn)
    def wrapper(*args, **kwargs):
        _require_session()
        return fn(*args, **kwargs)

    return wrapper


def roles_required(*roles):
    def decorator(fn):
        @wraps(fn)
        def wrapper(*args, **kwargs):
            user = _require_session()
            if user.role not in roles:
                security_event("auth.access.denied", "medium", "권한 없는 관리 API 접근 시도",
                               user_id=user.id, role=user.role, path=request.path)
                raise ApiError("FORBIDDEN", "이 작업을 할 권한이 없습니다.", 403)
            return fn(*args, **kwargs)

        return wrapper

    return decorator


def json_and_origin_required(fn):
    """로그인·회원가입: JSON 본문 + 허용 Origin(같은 출처)만 받는다."""
    @wraps(fn)
    def wrapper(*args, **kwargs):
        if not request.is_json:
            raise ApiError("UNSUPPORTED_MEDIA_TYPE", "JSON 요청만 허용합니다.", 415)
        origin = request.headers.get("Origin")
        if origin:
            o, h = urlsplit(origin), urlsplit(request.host_url)
            if (o.scheme, o.netloc) != (h.scheme, h.netloc):
                raise ApiError("ORIGIN_NOT_ALLOWED", "허용되지 않은 출처의 요청입니다.", 403)
        return fn(*args, **kwargs)

    return wrapper


def object_denied(kind: str, object_id, message: str):
    """남의 객체 접근: 이벤트를 남기고 존재 여부를 숨긴 404."""
    security_event("auth.object_access.denied", "medium", "다른 고객 데이터 접근 시도",
                   user_id=g.current_user.id if g.get("current_user") else None,
                   object_type=kind, object_id=object_id)
    return ApiError("NOT_FOUND", message, 404)
