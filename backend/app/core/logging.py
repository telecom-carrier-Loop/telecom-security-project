"""표준 출력 로그 + 요청 ID + 표준 보안 이벤트.

- 보안 이벤트 필드는 docs/contracts/observability/event-schema.md 를 따른다.
- 이벤트명은 통합 기준 12절 목록만 사용한다 (SECURITY_EVENT_TYPES).
- 비밀번호·세션·토큰·쿠키·결제 요청 전체는 기록하지 않는다.
"""
import json
import logging
import os
import re
import socket
import sys
import uuid
from datetime import datetime, timezone

from flask import current_app, g, has_request_context, request

SERVICE_NAME = "telecom-api"
HOST_NAME = os.getenv("HOSTNAME") or socket.gethostname()
REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9._:-]{8,128}$")

SECURITY_EVENT_TYPES = {
    "auth.login.failed", "auth.rate_limited", "auth.access.denied", "auth.object_access.denied",
    "payment.validation.failed", "payment.duplicate_request", "membership.redeem.denied",
}
SEVERITIES = ("info", "low", "medium", "high", "critical")


def utc_iso() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


class JsonFormatter(logging.Formatter):
    def format(self, record):
        base = {"timestamp": utc_iso(), "level": record.levelname, "service": SERVICE_NAME,
                "message": record.getMessage()}
        if has_request_context():
            base["request_id"] = g.get("request_id")
        extra = getattr(record, "event", None)
        if extra:
            base.update(extra)
        if record.exc_info:
            base["exception"] = self.formatException(record.exc_info)
        return json.dumps(base, ensure_ascii=False)


def setup_logging(app):
    handler = logging.StreamHandler(sys.stdout)  # 표준 출력 → 컨테이너 로그로 수집
    if app.config.get("LOG_FORMAT", "json") == "json":
        handler.setFormatter(JsonFormatter())
    else:
        handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    app.logger.handlers = [handler]
    app.logger.setLevel(app.config.get("LOG_LEVEL", "INFO"))

    @app.before_request
    def assign_request_id():
        # Nginx가 설정한 X-Request-ID를 이어 쓰고, 없거나 형식이 이상하면 새로 만든다
        given = request.headers.get("X-Request-ID", "")
        g.request_id = given if REQUEST_ID_RE.match(given) else uuid.uuid4().hex

    @app.after_request
    def add_request_id(response):
        response.headers["X-Request-ID"] = g.get("request_id", "")
        return response


def security_event(event_type: str, severity: str, title: str, **fields):
    """표준 이벤트 1건을 로그로 남긴다. D의 수집기가 이 줄을 그대로 읽는다."""
    assert event_type in SECURITY_EVENT_TYPES, event_type
    assert severity in SEVERITIES, severity
    event = {
        "schema_version": "1.0",
        "source": "flask-api",
        "event_id": f"{HOST_NAME}:{uuid.uuid4().hex}",
        "event_type": event_type,
        "detected_at": utc_iso(),
        "severity": severity,
        "title": title,
        "asset": {"host": HOST_NAME, "service": SERVICE_NAME},
        "request_id": g.get("request_id") if has_request_context() else None,
        "evidence": {k: v for k, v in fields.items() if v is not None},
    }
    current_app.logger.warning(event_type, extra={"event": event})
    return event


def app_log(message: str, **fields):
    """보안 이벤트가 아닌 일반 업무 로그 (예: 비밀번호 변경 완료)."""
    current_app.logger.info(message, extra={"event": {"evidence": fields}} if fields else None)


def client_ip() -> str:
    # ProxyFix가 승인된 한 단계 프록시의 X-Forwarded-For만 반영한다
    return request.remote_addr or "unknown"
