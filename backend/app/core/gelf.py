"""Graylog GELF(UDP) 로그 전송 — 로컬 실습용 (노션 실습과 같은 방식).

공용 PC 에서는 표준 출력 → 컨테이너 로그 수집이 정본이고, 이 핸들러는 GRAYLOG_GELF_HOST 를 넣었을 때만 켜진다.
- 보안 이벤트의 evidence 필드는 GELF 추가 필드로 펼친다 (예: evidence.src_ip → _src_ip)
  → Graylog 에서 실습처럼 `src_ip`, `account_hash`, `event_type` 으로 검색·집계할 수 있다
- 전송 실패는 무시한다 (로그 때문에 서비스가 멈추지 않게)
"""
import json
import logging
import re
import socket
import time
import zlib

SYSLOG_LEVEL = {"CRITICAL": 2, "ERROR": 3, "WARNING": 4, "INFO": 6, "DEBUG": 7}
FIELD_RE = re.compile(r"[^\w\.\-]")
# Graylog 기본 필드와 이름이 겹치면 덮어써지므로 바꿔서 보낸다
RENAMED = {"id": "field_id", "source": "event_source", "message": "event_message", "timestamp": "event_timestamp",
           "level": "event_level", "host": "event_host"}
MAX_UDP = 8192


def _flat(prefix, value, out):
    if isinstance(value, dict):
        for k, v in value.items():
            _flat(f"{prefix}_{k}" if prefix else str(k), v, out)
    elif value is not None:
        out[prefix] = value if isinstance(value, (int, float, str, bool)) else json.dumps(value, ensure_ascii=False)


class GelfUdpHandler(logging.Handler):
    def __init__(self, host: str, port: int = 12201, source: str = "telecom-api"):
        super().__init__()
        self.addr = (host, port)
        self.source = source
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)

    def build(self, record: logging.LogRecord) -> dict:
        msg = {"version": "1.1", "host": self.source, "short_message": record.getMessage()[:250],
               "timestamp": round(time.time(), 3), "level": SYSLOG_LEVEL.get(record.levelname, 6),
               "_logger": record.name}
        event = dict(getattr(record, "event", None) or {})
        evidence = event.pop("evidence", None) or {}
        fields = {}
        _flat("", event, fields)
        _flat("", evidence, fields)  # evidence 는 앞에 붙이지 않고 바로 펼친다 (src_ip, account_hash ...)
        for key, value in fields.items():
            name = FIELD_RE.sub("_", key)
            msg[f"_{RENAMED.get(name, name)}"] = value
        if record.exc_info:
            msg["full_message"] = logging.Formatter().formatException(record.exc_info)[:4000]
        return msg

    def emit(self, record):
        try:
            data = zlib.compress(json.dumps(self.build(record), ensure_ascii=False, default=str).encode())
            if len(data) <= MAX_UDP:
                self.sock.sendto(data, self.addr)
        except Exception:  # noqa: BLE001 — 로그 전송 실패가 요청 처리를 깨뜨리면 안 된다
            pass
