def test_live_has_request_id(client):
    res = client.get("/api/health/live")
    assert res.status_code == 200
    assert res.json["success"] is True and res.json["data"] == {"status": "ok"}
    assert res.json["request_id"] == res.headers["X-Request-ID"]


def test_request_id_from_proxy_is_reused(client):
    res = client.get("/api/health/live", headers={"X-Request-ID": "req-lab-0001"})
    assert res.json["request_id"] == "req-lab-0001"


def test_ready_checks_db(client):
    assert client.get("/api/health/ready").json["data"]["database"] == "ok"


def test_unknown_route_common_error(client):
    res = client.get("/api/nope")
    assert res.status_code == 404
    assert res.json["success"] is False and res.json["error"]["code"] == "NOT_FOUND" and res.json["request_id"]


def test_db_down_is_503(client, monkeypatch):
    from sqlalchemy.exc import OperationalError
    from app.auth import service

    def db_down(*a, **k):
        raise OperationalError("SELECT 1", {}, Exception("connection refused"))

    monkeypatch.setattr(service, "authenticate", db_down)
    res = client.post("/api/auth/login", json={"email": "a@b.c", "password": "x"})
    assert res.status_code == 503 and res.json["error"]["code"] == "DB_UNAVAILABLE"
