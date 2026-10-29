"""등급 변경은 포인트·관리자 권한과 독립적이고 차단 목록은 관리자 전용이다."""
import pytest

from app.extensions import db
from app.models import MembershipAccount, MembershipTier, PointTransaction, SecurityAuditLog, User
from app.models.base import utcnow
from tests.conftest import csrf, login, logout


def test_tier_names_and_admin_only_join_policy(client):
    login(client, "admin@test.local")
    tiers = client.get("/api/admin/membership/tiers").json["data"]["tiers"]
    assert [t["name"] for t in tiers] == ["일반유저", "Plus", "VIP"]
    assert [t["code"] for t in tiers] == ["GENERAL", "PLUS", "VIP"]


def test_customer_cannot_change_tier(client):
    login(client, "alice@test.local")
    assert client.get("/api/admin/membership/tiers").status_code == 403
    res = client.patch("/api/admin/membership/customers/2/tier", json={"rank": 3, "reason": "test"}, headers=csrf(client))
    assert res.status_code == 403


def test_admin_change_preserves_balance_role_and_writes_audit(client):
    login(client, "admin@test.local")
    account = MembershipAccount.query.filter_by(user_id=1).one()
    points, ledger = account.point_balance, PointTransaction.query.count()
    assert client.patch("/api/admin/membership/customers/1/tier", json={"rank": 2, "reason": "운영자 지정"}).status_code == 403
    res = client.patch("/api/admin/membership/customers/1/tier", json={"rank": 2, "reason": "운영자 지정"}, headers=csrf(client))
    assert res.status_code == 200
    membership = res.json["data"]["membership"]
    assert membership["tier"]["name"] == "VIP" and membership["tier"]["rank"] == 2
    assert membership["point_balance"] == points
    assert db.session.get(User, 1).role == "CUSTOMER"
    assert PointTransaction.query.count() == ledger
    record = SecurityAuditLog.query.filter_by(action="membership.tier.changed").one()
    assert record.actor_type == "ADMIN" and record.target == "1"
    assert "운영자 지정" in record.reason
    detail = client.get("/api/admin/customers/1").json["data"]["customer"]
    assert detail["membership"]["tier"] == "VIP"
    assert detail["membership"]["rank"] == 2
    logout(client)
    login(client, "alice@test.local")
    assert client.get("/api/membership/me").json["data"]["membership"]["tier"]["name"] == "VIP"
    assert client.get("/api/admin/dashboard").status_code == 403


@pytest.mark.parametrize("rank,reason", [(True, "test"), ("1", "test"), (-1, "test"), (3, "test"), (4, "test"), (None, "test"), (1, "  "), (1, "x" * 301)])
def test_tier_validation(client, rank, reason):
    login(client, "admin@test.local")
    assert client.patch("/api/admin/membership/customers/1/tier", json={"rank": rank, "reason": reason}, headers=csrf(client)).status_code == 422


def test_assign_unjoined_customer_no_bonus_and_reject_other_targets(client):
    user = User(name="등급 테스트", email="tier-test@example.invalid", role="CUSTOMER")
    user.set_password("Test1234!")
    db.session.add(user)
    db.session.commit()
    user_id = user.id
    login(client, "admin@test.local")
    payload = {"rank": 1, "reason": "미가입 회원 지정"}
    res = client.patch(f"/api/admin/membership/customers/{user_id}/tier", json=payload, headers=csrf(client))
    assert res.status_code == 200 and res.json["data"]["membership"]["point_balance"] == 0
    account = MembershipAccount.query.filter_by(user_id=user_id).one()
    assert PointTransaction.query.filter_by(account_id=account.id).count() == 0
    assert client.patch("/api/admin/membership/customers/3/tier", json=payload, headers=csrf(client)).status_code == 404
    user.is_active = False
    db.session.commit()
    assert client.patch(f"/api/admin/membership/customers/{user_id}/tier", json=payload, headers=csrf(client)).status_code == 409


def test_expensive_plan_never_auto_grants_admin_membership(client):
    client.post("/api/auth/register", json={"name": "새 회원", "email": "new-tier@example.invalid", "password": "Test1234!"})
    login(client, "new-tier@example.invalid")
    assert client.post("/api/subscriptions/me", json={"plan_id": 4}, headers=csrf(client)).status_code == 201
    res = client.post("/api/membership/join", headers=csrf(client))
    assert res.status_code == 201
    assert res.json["data"]["membership"]["tier"]["name"] == "VIP"
    assert res.json["data"]["membership"]["tier"]["rank"] == 2


def test_locked_accounts_only_active_locked_and_masked(client):
    alice, bob = db.session.get(User, 1), db.session.get(User, 2)
    alice.locked_at, alice.lock_reason = utcnow(), "수동 잠금"
    bob.locked_at, bob.is_active = utcnow(), False
    other = User(name="차단 관리자", email="locked-admin@example.invalid", role="ADMIN", locked_at=utcnow(), lock_reason="관리자 계정 잠금")
    other.set_password("Test1234!")
    db.session.add(other)
    db.session.commit()
    login(client, "admin@test.local")
    res = client.get("/api/admin/account-locks")
    assert res.status_code == 200
    data = res.json["data"]
    assert data["total"] == 2
    assert {u["role"] for u in data["accounts"]} == {"CUSTOMER", "ADMIN"}
    assert all("*" in u["email"] for u in data["accounts"])
    assert client.get("/api/admin/account-locks?q=nonexistent").json["data"]["total"] == 0


def test_locked_account_listing_requires_admin(client):
    assert client.get("/api/admin/account-locks").status_code == 401
    login(client, "alice@test.local")
    assert client.get("/api/admin/account-locks").status_code == 403


def test_legacy_admin_membership_hidden_from_customer_and_uses_vip_policy(client):
    from app.membership.service import payment_points
    account = MembershipAccount.query.filter_by(user_id=1).one()
    account.tier = MembershipTier.query.filter_by(rank=3).one()
    db.session.commit()
    login(client, "alice@test.local")
    membership = client.get("/api/membership/me").json["data"]["membership"]
    assert [t["name"] for t in membership["tiers"]] == ["일반유저", "Plus", "VIP"]
    assert membership["tier"]["name"] == "VIP" and membership["tier"]["rank"] == 2
    assert membership["point_balance"] == 12000
    assert membership["tier"]["earn_rate_bp"] == 200
    assert payment_points(account, 10000) == 200
    catalog = client.get("/api/membership/tiers").json["data"]["tiers"]
    assert len(catalog) == 3 and all(t["rank"] < 3 for t in catalog)
    summary = client.get("/api/dashboard/summary").json["data"]
    assert summary["membership"]["tier"] == "VIP"
    shop = client.get("/api/membership/shop").json["data"]
    assert shop["tier"] == {"name": "VIP", "rank": 2}
    assert all(i["min_tier_rank"] <= 2 for i in shop["items"])
    assert client.get("/api/admin/dashboard").status_code == 403


def test_customer_catalog_requires_login_and_rank_three_cannot_be_assigned(client):
    assert client.get("/api/membership/tiers").status_code == 401
    login(client, "admin@test.local")
    res = client.patch("/api/admin/membership/customers/1/tier", json={"rank": 3, "reason": "관리자 역할을 멤버십으로 지정 시도"}, headers=csrf(client))
    assert res.status_code == 422
    assert MembershipAccount.query.filter_by(user_id=1).one().tier.rank == 1
