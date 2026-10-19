"""공통 응답 형식 (docs/contracts/api-common.md)

정상: {"success": true, "data": {...}, "request_id": "..."}
오류: {"success": false, "error": {"code": "...", "message": "..."}, "request_id": "..."}
"""
from flask import g, has_request_context, jsonify


def _request_id():
    return g.get("request_id") if has_request_context() else None


def ok(data=None, status: int = 200):
    return jsonify({"success": True, "data": data if data is not None else {}, "request_id": _request_id()}), status


def fail(code: str, message: str, status: int, details=None, headers=None):
    error = {"code": code, "message": message}
    if details:
        error["details"] = details  # 입력 검증 실패 시 필드별 안내 (422)
    resp = jsonify({"success": False, "error": error, "request_id": _request_id()})
    return resp, status, (headers or {})
