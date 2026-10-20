"""보안 대시보드: 차단 IP·화이트리스트·계정 잠금·권한 회수·자동화 현황."""
import logging

from app.extensions import db
from app.models import AuthSession, IpBlock, SecurityAuditLog, User
from tests.conftest import csrf, login, logout, new_client

TOKEN = {"Authorization": "Bearer test-incident-token"}
APIKEY = {"X-API-Key": "test-incident-token"}  # 실습 n8n 노드 방식


def _from(ip):
    return {"X-Forwarded-For": ip}


def _events(caplog, name):
    return [r.event for r in caplog.records if getattr(r, "event", {}).get("event_type") == name]


# ---------- IP 차단 ----------

def test_seed_block_denies_api_without_expiry(client):
    res = client.get("/api/plans", headers=_from("203.0.113.44"))
    assert res.status_code == 403 and res.json["error"]["code"] == "IP_BLOCKED"
    body = res.get_data(as_text=True)
    assert "expires" not in body and "Retry-After" not in res.headers  # 차단자에게 해제 시각을 알려주지 않음
    assert client.get("/api/health/live", headers=_from("203.0.113.44")).status_code == 200  # 헬스는 예외


def test_block_hit_counted_and_first_hit_event(client, caplog):
    caplog.set_level(logging.INFO)
    for _ in range(3):
        client.get("/api/plans", headers=_from("203.0.113.44"))
    assert IpBlock.query.filter_by(ip="203.0.113.44").one().hit_count == 3
    assert len(_events(caplog, "security.ip.block_hit")) == 1


def test_automation_block_with_both_header_styles(client, caplog):
    caplog.set_level(logging.INFO)
    res = client.post("/api/internal/ip-blocks", json={"src_ip": "198.51.100.7", "reason": "5회 실패"},
                      headers={**APIKEY, "X-Workflow": "4-ip-block"})
    assert res.status_code == 201 and res.json["data"] == {"ip": "198.51.100.7", "blocked": True, "result": "CREATED"}
    again = client.post("/api/internal/ip-blocks", json={"ip": "198.51.100.7"}, headers=TOKEN)
    assert again.status_code == 200 and again.json["data"]["result"] == "ALREADY"  # 이미 차단된 IP
    assert "expires_at" not in again.json["data"]
    assert client.get("/api/plans", headers=_from("198.51.100.7")).status_code == 403
    assert _events(caplog, "security.ip.blocked")[0]["evidence"]["workflow"] == "4-ip-block"


def test_automation_token_required(client):
    assert client.post("/api/internal/ip-blocks", json={"ip": "198.51.100.7"}).status_code == 401
    assert client.post("/api/internal/ip-blocks", json={"ip": "198.51.100.7"},
                       headers={"X-API-Key": "wrong"}).status_code == 401
    assert client.post("/api/internal/ip-blocks", json={"ip": "not-an-ip"}, headers=TOKEN).status_code == 422


def test_whitelist_is_never_blocked(client):
    res = client.post("/api/internal/ip-blocks", json={"ip": "127.0.0.1"}, headers=TOKEN)
    assert res.json["data"] == {"ip": "127.0.0.1", "blocked": False, "result": "WHITELISTED"}


def test_admin_manages_blocks_and_sees_expiry(client):
    login(client, "admin@test.local")
    res = client.post("/api/admin/ip-blocks", json={"ips": "198.51.100.1, 198.51.100.2", "reason": "수동", "minutes": 30},
                      headers=csrf(client))
    assert [r["result"] for r in res.json["data"]["results"]] == ["CREATED", "CREATED"]
    data = client.get("/api/admin/ip-blocks").json["data"]
    assert data["total"] == 3 and all(b["expires_at"] for b in data["blocks"])  # 관리자는 해제 시각을 봄
    assert data["blocks"][0]["firewall_status"] == "SKIPPED"  # 방화벽 연동 자리 (지금은 미연동)
    ids = [b["id"] for b in data["blocks"] if b["ip"].startswith("198.51.100.")]
    assert client.post("/api/admin/ip-blocks/release", json={"ids": ids}, headers=csrf(client)).json["data"]["released"] == 2
    assert client.get("/api/plans", headers=_from("198.51.100.1")).status_code == 200


def test_admin_cannot_block_own_ip(client):
    login(client, "admin@test.local")
    res = client.post("/api/admin/ip-blocks", json={"ips": ["198.51.100.9"]},
                      headers={**csrf(client), **_from("198.51.100.9")})
    assert res.json["data"]["results"][0]["result"] == "SELF"


def test_whitelist_add_releases_existing_block(client):
    login(client, "admin@test.local")
    res = client.post("/api/admin/ip-whitelist", json={"cidr": "203.0.113.0/24", "memo": "실습망"}, headers=csrf(client))
    assert res.status_code == 201
    assert client.get("/api/plans", headers=_from("203.0.113.44")).status_code == 200
    assert client.post("/api/admin/ip-whitelist", json={"cidr": "bad"}, headers=csrf(client)).status_code == 422


def test_customer_cannot_use_admin_block_api(client):
    login(client, "alice@test.local")
    assert client.get("/api/admin/ip-blocks").status_code == 403


# ---------- 계정 잠금 ----------

def test_admin_lock_revokes_session_and_blocks_login(client, app):
    other = new_client(app)
    login(other, "bob@test.local")
    login(client, "admin@test.local")
    assert client.post("/api/admin/customers/2/lock", json={"reason": "의심 거래"}, headers=csrf(client)).status_code == 200
    assert other.get("/api/auth/me").status_code == 401  # 잠그는 즉시 로그아웃
    wrong = login(other, "bob@test.local", "wrong-pass1")
    right = login(other, "bob@test.local")
    assert wrong.status_code == 401  # 비밀번호가 틀리면 잠김 여부를 알려주지 않음
    assert right.status_code == 403 and right.json["error"]["code"] == "ACCOUNT_LOCKED"
    row = next(c for c in client.get("/api/admin/customers?status=LOCKED").json["data"]["customers"])
    assert row["status"] == "LOCKED" and row["lock_reason"] == "의심 거래"
    client.post("/api/admin/customers/2/unlock", headers=csrf(client))
    assert login(other, "bob@test.local").status_code == 200


def test_bulk_lock_and_deactivate(client):
    login(client, "admin@test.local")
    res = client.post("/api/admin/customers/bulk", json={"action": "lock", "ids": [1, 2, 3]}, headers=csrf(client))
    assert res.json["data"]["changed"] == 2  # 3번은 관리자 → 제외
    client.post("/api/admin/customers/bulk", json={"action": "unlock", "ids": [1, 2]}, headers=csrf(client))
    assert client.post("/api/admin/customers/2/deactivate", json={"reason": "요청"}, headers=csrf(client)).status_code == 200
    assert db.session.get(User, 2).is_active is False
    assert client.post("/api/admin/customers/3/lock", headers=csrf(client)).status_code == 404  # 관리자는 고객 API 대상 아님


def test_automation_account_lock(client):
    res = client.post("/api/internal/account-locks", json={"username": "alice@test.local", "reason": "브루트포스"},
                      headers={**TOKEN, "X-Workflow": "8-login-bruteforce"})
    assert res.status_code == 201 and res.json["data"]["result"] == "CREATED"
    admin = client.post("/api/internal/account-locks", json={"email": "admin@test.local"}, headers=TOKEN)
    assert admin.json["data"]["result"] == "ADMIN_PROTECTED"  # 자동화는 관리자를 잠그지 않음
    ghost = client.post("/api/internal/account-locks", json={"email": "ghost@test.local"}, headers=TOKEN)
    assert ghost.json["data"]["result"] == "NOT_FOUND"


# ---------- 권한 점검·회수 ----------

def _make_admin(email):
    u = User(email=email, name="임시관리자", role="ADMIN")
    u.set_password("Test1234!")
    db.session.add(u)
    db.session.commit()
    return u


def test_privilege_violation_and_auto_revoke(client, caplog):
    caplog.set_level(logging.INFO)
    rogue = _make_admin("rogue@test.local")
    res = client.get("/api/internal/privilege-violations", headers={**TOKEN, "X-Workflow": "1-priv-guard"})
    assert [v["email"] for v in res.json["data"]["violations"]] == ["rogue@test.local"]
    assert _events(caplog, "auth.privilege.violation")
    kept = client.post("/api/internal/role-revocations", json={"email": "admin@test.local"}, headers=TOKEN)
    assert kept.json["data"]["result"] == "IN_ALLOWLIST"  # 허용목록 관리자는 자동화가 못 건드림
    done = client.post("/api/internal/role-revocations", json={"email": "rogue@test.local"}, headers=TOKEN)
    assert done.status_code == 201 and db.session.get(User, rogue.id).role == "CUSTOMER"
    assert _events(caplog, "auth.role.revoked")[0]["severity"] == "high"


def test_manual_revoke_rules(client, app):
    login(client, "admin@test.local")
    me = client.get("/api/auth/me").json["data"]["user"]["id"]
    assert client.post(f"/api/admin/users/{me}/revoke-admin", headers=csrf(client)).json["error"]["code"] == "SELF_REVOKE"
    rogue = _make_admin("second@test.local")
    other = new_client(app)
    login(other, "second@test.local")
    data = client.get("/api/admin/privileges").json["data"]
    assert data["violations"] == 1 and {a["email"]: a["in_allowlist"] for a in data["admins"]}["second@test.local"] is False
    assert client.post(f"/api/admin/users/{rogue.id}/revoke-admin", json={"reason": "과잉 권한"},
                       headers=csrf(client)).status_code == 200
    assert other.get("/api/admin/dashboard").status_code == 401  # 회수 → 세션 폐기
    assert AuthSession.query.filter_by(user_id=rogue.id, revoked_at=None).count() == 0


def test_last_admin_cannot_be_revoked(client, app):
    second = _make_admin("second@test.local")
    other = new_client(app)
    login(other, "second@test.local")
    first_id = User.query.filter_by(email="admin@test.local").one().id
    assert other.post(f"/api/admin/users/{first_id}/revoke-admin", headers=csrf(other)).status_code == 200
    # 이제 second 혼자 남음 → 본인 회수 금지, 다른 관리자 없음
    assert other.post(f"/api/admin/users/{second.id}/revoke-admin", headers=csrf(other)).json["error"]["code"] in ("SELF_REVOKE", "LAST_ADMIN")


# ---------- 자동화 현황 ----------

def test_automation_status_groups_by_workflow(client):
    client.post("/api/internal/ip-blocks", json={"ip": "198.51.100.20"}, headers={**TOKEN, "X-Workflow": "9-snort-ip-block"})
    client.post("/api/internal/account-locks", json={"email": "bob@test.local"},
                headers={**TOKEN, "X-Workflow": "8-login-bruteforce"})
    login(client, "admin@test.local")
    flows = {w["key"]: w for w in client.get("/api/admin/automation-status").json["data"]["workflows"]}
    assert flows["9-snort-ip-block"]["today"] == 1 and flows["9-snort-ip-block"]["by_action"] == {"IP 차단": 1}
    assert flows["8-login-bruteforce"]["by_action"] == {"계정 잠금": 1}
    assert flows["4-ip-block"]["last_at"]  # 시드의 자동 차단 기록
    assert flows["6-incident"]["webhook"] == "/webhook/incident"
    assert SecurityAuditLog.query.filter_by(actor_type="AUTOMATION").count() >= 3
