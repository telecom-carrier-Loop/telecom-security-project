import logging
from datetime import timedelta

from app.extensions import db
from app.models import AuthSession, User
from tests.conftest import HOST, csrf, login, logout, new_client

COOKIE = "__Host-telecom_session"


def _set_cookie_header(res):
    return " ".join(res.headers.getlist("Set-Cookie"))


def test_register_hashes_with_argon2id_and_ignores_role(client):
    res = client.post("/api/auth/register", json={"email": "New@Test.local", "password": "abcd1234",
                                                  "name": "새고객", "role": "SECURITY_ADMIN"})
    assert res.status_code == 201 and res.json["data"]["user"]["role"] == "CUSTOMER"
    user = User.query.filter_by(email="new@test.local").one()
    assert user.password_hash.startswith("$argon2id$v=19$m=65536,t=3,p=1$")


def test_register_validation_is_422(client):
    res = client.post("/api/auth/register", json={"email": "bad", "password": "short", "name": ""})
    assert res.status_code == 422
    assert set(res.json["error"]["details"]) == {"email", "password", "name"}


def test_register_duplicate_409(client):
    res = client.post("/api/auth/register", json={"email": "alice@test.local", "password": "abcd1234", "name": "x"})
    assert res.status_code == 409


def test_login_requires_json_and_same_origin(client):
    assert client.post("/api/auth/login", data="email=a").status_code == 415
    res = client.post("/api/auth/login", json={"email": "alice@test.local", "password": "Test1234!"},
                      headers={"Origin": "https://evil.example"})
    assert res.status_code == 403 and res.json["error"]["code"] == "ORIGIN_NOT_ALLOWED"
    ok = client.post("/api/auth/login", json={"email": "alice@test.local", "password": "Test1234!"},
                     headers={"Origin": "https://portal.telecom.test"})
    assert ok.status_code == 200


def test_session_cookie_flags_and_db_hash(client, app):
    res = login(client, "alice@test.local")
    header = _set_cookie_header(res)
    assert f"{COOKIE}=" in header
    for flag in ("Secure", "HttpOnly", "SameSite=Lax", "Path=/"):
        assert flag in header
    assert "Domain=" not in header
    raw = client.get_cookie(COOKIE, domain=HOST).value
    assert raw not in res.get_data(as_text=True)  # 세션 원문은 본문에 없음
    stored = AuthSession.query.one()
    assert stored.token_hash != raw and len(stored.token_hash) == 64  # DB에는 SHA-256 해시만


def test_same_session_works_on_another_app_instance(client, app):
    """두 API Pod 교차 인증: 다른 앱 인스턴스(같은 DB)에서도 같은 쿠키로 인증된다."""
    login(client, "alice@test.local")
    raw = client.get_cookie(COOKIE, domain=HOST).value
    other = new_client(app)  # 메모리를 공유하지 않는 새 클라이언트, 같은 DB
    other.set_cookie(COOKIE, raw, domain=HOST, secure=True)
    assert other.get("/api/auth/me").json["data"]["user"]["email"] == "alice@test.local"


def test_wrong_password_and_unknown_account_look_the_same(client):
    a = login(client, "alice@test.local", "wrong-pass1")
    b = login(client, "nobody@test.local", "wrong-pass1")
    assert a.status_code == b.status_code == 401 and a.json["error"] == b.json["error"]


def test_account_limit_5_per_15min_with_retry_after(client):
    for _ in range(5):
        login(client, "bob@test.local", "wrong-pass1")
    res = login(client, "bob@test.local")  # 맞는 비밀번호여도 제한
    assert res.status_code == 429 and int(res.headers["Retry-After"]) > 0


def test_ip_limit_20_per_15min(client):
    for i in range(20):
        login(client, f"user{i}@test.local", "wrong-pass1")  # 계정은 매번 다르지만 같은 IP
    assert login(client, "alice@test.local").status_code == 429


def test_unknown_account_is_also_limited(client):
    for _ in range(5):
        login(client, "ghost@test.local", "wrong-pass1")
    assert login(client, "ghost@test.local", "wrong-pass1").status_code == 429


def test_csrf_required_for_state_change(client):
    login(client, "alice@test.local")
    assert client.post("/api/auth/logout").status_code == 403
    assert client.post("/api/auth/logout", headers={"X-CSRF-Token": "wrong"}).status_code == 403
    assert client.post("/api/auth/logout", headers=csrf(client)).status_code == 200
    assert client.get("/api/auth/me").status_code == 401  # DB 세션 폐기됨


def test_idle_timeout_30min(client, app):
    login(client, "alice@test.local")
    s = AuthSession.query.one()
    s.last_seen_at -= timedelta(minutes=31)
    db.session.commit()
    assert client.get("/api/auth/me").status_code == 401


def test_absolute_timeout_8h(client, app):
    login(client, "alice@test.local")
    s = AuthSession.query.one()
    s.expires_at -= timedelta(hours=8, minutes=1)
    db.session.commit()
    assert client.get("/api/auth/me").status_code == 401


def test_failed_login_event_follows_schema(client, caplog):
    caplog.set_level(logging.INFO)
    login(client, "alice@test.local", "wrong-pass1")
    ev = next(getattr(r, "event") for r in caplog.records if getattr(r, "event", {}).get("event_type") == "auth.login.failed")
    for key in ("schema_version", "source", "event_id", "event_type", "detected_at", "severity", "title", "asset"):
        assert key in ev
    assert ev["detected_at"].endswith("Z") and ev["severity"] == "low"
    assert "wrong-pass1" not in str(ev)


# ---------- 프로필 ----------

def test_profile_shows_previous_login_and_failures(client):
    login(client, "alice@test.local")
    logout(client)
    login(client, "alice@test.local", "wrong-pass1")
    login(client, "alice@test.local", "wrong-pass1")
    login(client, "alice@test.local")
    user = client.get("/api/auth/me").json["data"]["user"]
    assert user["previous_login_at"] and user["failed_attempts_before_login"] == 2
    assert user["membership_joined"] is True and "password_hash" not in user


def test_update_name_only(client):
    login(client, "alice@test.local")
    res = client.patch("/api/auth/me", json={"name": "김하늘2", "role": "SECURITY_ADMIN", "email": "x@test.local"},
                       headers=csrf(client))
    user = res.json["data"]["user"]
    assert user["name"] == "김하늘2" and user["role"] == "CUSTOMER" and user["email"] == "alice@test.local"


def test_change_password_revokes_all_sessions(client, app):
    login(client, "alice@test.local")
    other = new_client(app)
    login(other, "alice@test.local")  # 다른 기기 세션
    bad = client.post("/api/auth/password", headers=csrf(client),
                      json={"current_password": "nope1234", "new_password": "newpass123"})
    assert bad.status_code == 422
    res = client.post("/api/auth/password", headers=csrf(client),
                      json={"current_password": "Test1234!", "new_password": "newpass123"})
    assert res.status_code == 200
    assert client.get("/api/auth/me").status_code == 401
    assert other.get("/api/auth/me").status_code == 401  # 다른 기기도 로그아웃
    assert login(client, "alice@test.local", "newpass123").status_code == 200


def test_deactivate(client):
    login(client, "bob@test.local")
    assert client.post("/api/auth/deactivate", json={"password": "Test1234!"}, headers=csrf(client)).status_code == 200
    assert client.get("/api/auth/me").status_code == 401
    assert login(client, "bob@test.local").status_code == 401


def test_admin_cannot_self_deactivate(client):
    login(client, "admin@test.local")
    assert client.post("/api/auth/deactivate", json={"password": "Test1234!"}, headers=csrf(client)).status_code == 403
