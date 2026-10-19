from app.extensions import db
from app.models import MembershipAccount, PointTransaction
from tests.conftest import csrf, login, logout


def _key(k):
    return {"Idempotency-Key": k}


def _new_customer(client):
    client.post("/api/auth/register", json={"email": "m@test.local", "password": "abcd1234", "name": "신규"})
    login(client, "m@test.local", "abcd1234")


def test_join_once(client):
    _new_customer(client)
    assert client.get("/api/membership/me").json["data"]["membership"] == {"joined": False}
    res = client.post("/api/membership/join", headers=csrf(client))
    assert res.status_code == 201 and res.json["data"]["membership"]["point_balance"] == 1000
    assert client.post("/api/membership/join", headers=csrf(client)).status_code == 409


def test_redeem_uses_server_cost(client):
    login(client, "alice@test.local")
    res = client.post("/api/membership/benefits/1/redeem", json={"required_points": 1},
                      headers=csrf(client, **_key("redeem-0001")))
    assert res.status_code == 201 and res.json["data"]["point_balance"] == 10000
    last = PointTransaction.query.order_by(PointTransaction.id.desc()).first()
    assert last.amount == -2000 and last.business_ref.startswith("redemption:")


def test_same_key_same_body_replays(client):
    login(client, "alice@test.local")
    h = csrf(client, **_key("redeem-same-01"))
    first = client.post("/api/membership/benefits/1/redeem", headers=h)
    again = client.post("/api/membership/benefits/1/redeem", headers=h)
    assert first.status_code == 201 and again.status_code == 200 and again.json["data"]["replayed"] is True
    assert again.json["data"]["point_balance"] == 10000


def test_same_key_different_body_409(client):
    login(client, "alice@test.local")
    h = csrf(client, **_key("redeem-diff-01"))
    client.post("/api/membership/benefits/1/redeem", headers=h)
    res = client.post("/api/membership/benefits/3/redeem", headers=h)
    assert res.status_code == 409 and res.json["error"]["code"] == "IDEMPOTENCY_CONFLICT"


def test_key_required_and_monthly_limit(client):
    login(client, "alice@test.local")
    assert client.post("/api/membership/benefits/1/redeem", headers=csrf(client)).status_code == 422
    client.post("/api/membership/benefits/1/redeem", headers=csrf(client, **_key("lim-000001")))
    res = client.post("/api/membership/benefits/1/redeem", headers=csrf(client, **_key("lim-000002")))
    assert res.json["error"]["code"] == "LIMIT_REACHED"


def test_insufficient_points(client):
    login(client, "bob@test.local")
    res = client.post("/api/membership/benefits/2/redeem", headers=csrf(client, **_key("poor-00001")))
    assert res.json["error"]["code"] == "INSUFFICIENT_POINTS"


def test_balance_never_negative(app):
    acc = MembershipAccount.query.filter_by(user_id=2).one()
    acc.point_balance = -1
    try:
        db.session.commit()
        assert False
    except Exception:
        db.session.rollback()


def test_policy_admin_but_no_balance_edit(client):
    login(client, "alice@test.local")
    assert client.patch("/api/admin/membership/benefits/1", json={"required_points": 1}, headers=csrf(client)).status_code == 403
    logout(client)
    login(client, "support@test.local")
    res = client.patch("/api/admin/membership/benefits/1", json={"required_points": 2500, "is_active": False},
                       headers=csrf(client))
    assert res.json["data"]["benefit"] == {**res.json["data"]["benefit"], "required_points": 2500, "is_active": False}
    assert client.patch("/api/admin/membership/benefits/1", json={"required_points": -5}, headers=csrf(client)).status_code == 422
    logout(client)
    login(client, "security@test.local")
    assert client.get("/api/admin/membership/benefits").status_code == 403
