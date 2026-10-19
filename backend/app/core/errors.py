from flask import current_app
from sqlalchemy.exc import OperationalError
from werkzeug.exceptions import HTTPException

from .responses import fail


class ApiError(Exception):
    """서비스 코드에서 raise 하면 공통 오류 응답으로 바뀐다."""

    def __init__(self, code: str, message: str, status: int = 400, details=None, headers=None):
        super().__init__(message)
        self.code, self.message, self.status = code, message, status
        self.details, self.headers = details, headers


def validation_error(details: dict):
    return ApiError("VALIDATION_ERROR", "입력값을 확인하세요.", 422, details=details)


def not_found(message="요청한 리소스를 찾을 수 없습니다."):
    return ApiError("NOT_FOUND", message, 404)


HTTP_CODES = {
    400: ("BAD_REQUEST", "요청 형식이 올바르지 않습니다."),
    401: ("UNAUTHORIZED", "인증이 필요합니다."),
    403: ("FORBIDDEN", "이 작업을 할 권한이 없습니다."),
    404: ("NOT_FOUND", "요청한 리소스를 찾을 수 없습니다."),
    405: ("METHOD_NOT_ALLOWED", "허용되지 않은 메서드입니다."),
    409: ("CONFLICT", "현재 상태와 충돌하는 요청입니다."),
    413: ("PAYLOAD_TOO_LARGE", "요청 본문이 너무 큽니다."),
    415: ("UNSUPPORTED_MEDIA_TYPE", "JSON 요청만 허용합니다."),
    422: ("VALIDATION_ERROR", "입력값을 확인하세요."),
    429: ("TOO_MANY_REQUESTS", "요청이 너무 많습니다. 잠시 후 다시 시도하세요."),
}


def register_error_handlers(app):
    @app.errorhandler(ApiError)
    def handle_api_error(err: ApiError):
        return fail(err.code, err.message, err.status, err.details, err.headers)

    @app.errorhandler(HTTPException)
    def handle_http(err: HTTPException):
        code, message = HTTP_CODES.get(err.code, ("HTTP_ERROR", err.description))
        return fail(code, message, err.code)

    @app.errorhandler(OperationalError)
    def handle_db_down(err: OperationalError):
        # DB 연결 불가 (DB VIP 전환 중, 접속 정보 오류 등) → 의존성 장애 503
        current_app.logger.exception("database_unavailable")
        return fail("DB_UNAVAILABLE", "데이터베이스에 연결할 수 없습니다.", 503, _debug_detail(err))

    @app.errorhandler(Exception)
    def handle_unexpected(err: Exception):
        current_app.logger.exception("unhandled_error")
        return fail("INTERNAL_ERROR", "서버 내부 오류가 발생했습니다.", 500, _debug_detail(err))


def _debug_detail(err: Exception):
    # 개발 서버(debug)에서만 원인을 응답에 담는다. 그 외에는 로그에만 남긴다.
    if current_app.debug:
        return {"exception": type(err).__name__, "message": str(err).splitlines()[0][:300]}
    return None
