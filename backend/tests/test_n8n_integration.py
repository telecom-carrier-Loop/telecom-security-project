"""n8n·Graylog 연동용 변경: 로그 필드, 계정 해시 잠금, GELF, 프록시 단계."""
import hashlib
import json
import logging
import socket
import zlib

from app import create_app
from app.config import TestConfig
from app.core.gelf import GelfUdpHandler
from app.extensions import db
from app.models import User
from tests.conftest import login

TOKEN = {"X-API-Key": "test-incident-token", "X-Workflow": "8-login-bruteforce"}


def _event(caplog, name):
    return next(r.event for r in caplog.records if getattr(r, "event", {}).get("event_type") == name)


def test_login_failed_event_has_src_ip_and_account_hash(client, caplog):
    caplog.set_level(logging.INFO)
    client.post("/api/auth/login", json={"email": "Alice@Test.local", "password": "wrong-pass1"},
                headers={"X-Forwarded-For": "198.51.100.30"})
    ev = _event(caplog, "auth.login.failed")["evidence"]
    assert ev["src_ip"] == "198.51.100.30"
    assert ev["account_hash"] == hashlib.sha256(b"alice@test.local").hexdigest()  # 소문자로 정규화
    assert "alice" not in json.dumps(ev)  # 이메일 원문은 남기지 않음


def test_account_lock_by_hash(client):
    acc = hashlib.sha256(b"bob@test.local").hexdigest()
    res = client.post("/api/internal/account-locks", json={"account_hash": acc, "reason": "브루트포스"}, headers=TOKEN)
    assert res.status_code == 201 and res.json["data"]["result"] == "CREATED"
    assert db.session.get(User, 2).locked_at is not None
    assert client.post("/api/internal/account-locks", json={"account_hash": "xyz"}, headers=TOKEN).status_code == 422
    unknown = client.post("/api/internal/account-locks", json={"account_hash": "0" * 64}, headers=TOKEN)
    assert unknown.json["data"]["result"] == "NOT_FOUND"


def test_gelf_handler_flattens_evidence():
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind(("127.0.0.1", 0))
    receiver.settimeout(2)
    handler = GelfUdpHandler("127.0.0.1", receiver.getsockname()[1])
    record = logging.LogRecord("app", logging.WARNING, __file__, 1, "auth.login.failed", None, None)
    record.event = {"event_type": "auth.login.failed", "severity": "low", "source": "flask-api", "asset": {"host": "pc1"},
                    "evidence": {"src_ip": "198.51.100.30", "account_hash": "a" * 64}}
    handler.emit(record)
    msg = json.loads(zlib.decompress(receiver.recv(8192)))
    assert msg["version"] == "1.1" and msg["short_message"] == "auth.login.failed" and msg["level"] == 4
    assert msg["_event_type"] == "auth.login.failed" and msg["_src_ip"] == "198.51.100.30"
    assert msg["_account_hash"] == "a" * 64 and msg["_asset_host"] == "pc1"
    assert msg["_event_source"] == "flask-api" and "_source" not in msg  # Graylog 기본 필드와 충돌 방지


def test_direct_mode_ignores_spoofed_forwarded_for():
    class DirectConfig(TestConfig):
        TRUSTED_PROXY_HOPS = 0

    app = create_app(DirectConfig)
    with app.app_context():
        db.create_all()
        from app.cli import load_seed_module
        load_seed_module().seed_data()
        c = app.test_client()
        # 203.0.113.44 는 시드에서 차단된 IP. 프록시를 믿지 않으면 헤더를 꾸며도 실제 접속 IP(127.0.0.1)로 판단
        assert c.get("/api/plans", headers={"X-Forwarded-For": "203.0.113.44"}).status_code == 200
        db.session.remove()
        db.drop_all()


def test_proxy_mode_uses_forwarded_for(client):
    assert client.get("/api/plans", headers={"X-Forwarded-For": "203.0.113.44"}).status_code == 403
