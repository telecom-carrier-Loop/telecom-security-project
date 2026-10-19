"""요청 본문 검증·멱등 키 도우미. 허용한 필드만 꺼내 쓰고, 나머지는 무시한다."""
import hashlib
import json

from flask import request

from .errors import ApiError, validation_error


def body() -> dict:
    data = request.get_json(silent=True)
    return data if isinstance(data, dict) else {}


def text(data: dict, key: str, label: str, min_len: int = 1, max_len: int = 255, errors=None) -> str:
    value = data.get(key)
    value = value.strip() if isinstance(value, str) else ""
    if not min_len <= len(value) <= max_len and errors is not None:
        errors[key] = f"{label}은(는) {min_len}~{max_len}자로 입력하세요."
    return value


def raise_if(errors: dict):
    if errors:
        raise validation_error(errors)


def idempotency_key() -> str:
    """결제·혜택 사용 요청의 Idempotency-Key (사용자+작업+키로 고유 저장)."""
    key = (request.headers.get("Idempotency-Key") or "").strip()
    if not 8 <= len(key) <= 64:
        raise ApiError("IDEMPOTENCY_KEY_REQUIRED", "Idempotency-Key 헤더가 필요합니다.", 422)
    return key


def request_hash(operation: str, payload: dict) -> str:
    """작업 이름 + 정규화한 본문의 SHA-256. 같은 키에 다른 내용이 오면 409로 거절할 때 쓴다."""
    canonical = json.dumps({"op": operation, "body": payload}, sort_keys=True, ensure_ascii=False, separators=(",", ":"))
    return hashlib.sha256(canonical.encode()).hexdigest()


def idempotency_conflict():
    return ApiError("IDEMPOTENCY_CONFLICT", "같은 Idempotency-Key로 다른 요청이 이미 처리되었습니다.", 409)
