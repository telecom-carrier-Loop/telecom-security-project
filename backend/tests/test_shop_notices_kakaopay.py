"""포인트 상점 · 등급별 적립률 · 공지사항 · 카카오페이 테스트 결제."""
import uuid

import pytest

from app.extensions import db
from app.models import Invoice, MembershipAccount, Notice, Payment, PointTransaction, ShopItem, User
from app.payments import kakaopay
from tests.conftest import csrf, login


def idem(client):
    return csrf(client, **{"Idempotency-Key": str(uuid.uuid4())})


def _alice():
    return User.query.filter_by(email="alice@test.local").one()


# ---------- 등급별 적립률 ----------

def test_payment_points_follow_tier_rate(client):
    login(client, "alice@test.local")  # Silver = 1%
    inv = Invoice.query.filter_by(user_id=_alice().id, status="UNPAID").first()
    res = client.post("/api/payments", json={"invoice_id": inv.id, "card_number": "4242424242424242"}, headers=idem(client))
    assert res.json["data"]["payment"]["status"] == "SUCCEEDED"
    earned = PointTransaction.query.filter_by(business_ref=f"payment:{res.json['data']['payment']['id']}").one()
    assert earned.amount == inv.amount * 100 // 10000
    acc = MembershipAccount.query.filter_by(user_id=_alice().id).one()
    acc.tier.earn_rate_bp = 300  # VIP 수준으로 바꾸면 3%
    db.session.commit()


def test_membership_me_shows_rate(client):
    login(client, "bob@test.local")  # Gold
    tiers = {t.code: t.earn_rate_bp for t in __import__("app.models", fromlist=["MembershipTier"]).MembershipTier.query.all()}
    assert tiers == {"BASIC": 50, "SILVER": 100, "GOLD": 200, "VIP": 300}


# ---------- 포인트 상점 ----------

def test_shop_purchase_deducts_points_and_stock(client):
    login(client, "alice@test.local")  # Silver(rank 1), 12,000P
    data = client.get("/api/membership/shop").json["data"]
    by = {i["name"]: i for i in data["items"]}
    assert by["L∞P 텀블러"]["available"] is True and by["무선 이어폰"]["available"] is False  # VIP 전용
    item = ShopItem.query.filter_by(name="편의점 3,000원 상품권").one()
    h = idem(client)
    res = client.post(f"/api/membership/shop/{item.id}/purchase", headers=h)
    assert res.status_code == 201 and res.json["data"]["balance"] == 12000 - 3000
    again = client.post(f"/api/membership/shop/{item.id}/purchase", headers=h)  # 같은 키 재전송
    assert again.json["data"]["replayed"] is True
    db.session.refresh(item)
    assert item.stock == 99
    assert client.get("/api/membership/shop/orders").json["data"]["orders"][0]["code"].startswith("LOOP-")


def test_shop_tier_and_points_and_soldout(client):
    login(client, "alice@test.local")
    vip = ShopItem.query.filter_by(name="무선 이어폰").one()
    assert client.post(f"/api/membership/shop/{vip.id}/purchase", headers=idem(client)).json["error"]["code"] == "TIER_REQUIRED"
    big = ShopItem(name="고가 상품", price_points=999999, stock=None, min_tier_rank=0)
    gone = ShopItem(name="품절 상품", price_points=10, stock=0, min_tier_rank=0)
    db.session.add_all([big, gone]); db.session.commit()
    assert client.post(f"/api/membership/shop/{big.id}/purchase", headers=idem(client)).json["error"]["code"] == "INSUFFICIENT_POINTS"
    assert client.post(f"/api/membership/shop/{gone.id}/purchase", headers=idem(client)).json["error"]["code"] == "SOLD_OUT"


def test_shop_admin_manage(client):
    login(client, "alice@test.local")
    assert client.post("/api/admin/membership/shop-items", json={"name": "x", "price_points": 1}, headers=csrf(client)).status_code == 403
    client.post("/api/auth/logout", headers=csrf(client))
    login(client, "admin@test.local")
    res = client.post("/api/admin/membership/shop-items", json={"name": "새 상품", "price_points": 500, "stock": 5,
                                                                "min_tier_rank": 0, "category": "COUPON"}, headers=csrf(client))
    assert res.status_code == 201
    item_id = res.json["data"]["item"]["id"]
    assert client.patch(f"/api/admin/membership/shop-items/{item_id}", json={"price_points": 0}, headers=csrf(client)).status_code == 422
    assert client.patch(f"/api/admin/membership/shop-items/{item_id}", json={"is_active": False}, headers=csrf(client)).json["data"]["item"]["is_active"] is False


# ---------- 공지사항 ----------

def test_notices_public_and_admin(client):
    data = client.get("/api/notices").json["data"]  # 로그인 없이 볼 수 있음
    assert data["total"] == 3 and data["notices"][0]["is_pinned"] is True
    nid = data["notices"][0]["id"]
    assert "content" in client.get(f"/api/notices/{nid}").json["data"]["notice"]
    login(client, "admin@test.local")
    res = client.post("/api/admin/notices", json={"title": "<script>alert(1)</script>", "content": "본문",
                                                  "category": "GENERAL", "is_published": False}, headers=csrf(client))
    hidden = res.json["data"]["notice"]["id"]
    assert client.get(f"/api/notices/{hidden}").status_code == 404  # 비공개는 고객에게 안 보임
    assert client.patch(f"/api/admin/notices/{hidden}", json={"is_published": True}, headers=csrf(client)).status_code == 200
    assert client.get(f"/api/notices/{hidden}").json["data"]["notice"]["title"] == "<script>alert(1)</script>"  # 평문 그대로
    assert client.delete(f"/api/admin/notices/{hidden}", headers=csrf(client)).status_code == 200
    assert client.post("/api/admin/notices", json={"title": "", "content": ""}, headers=csrf(client)).status_code == 422


def test_notice_admin_only(client):
    login(client, "alice@test.local")
    assert client.post("/api/admin/notices", json={"title": "a", "content": "b"}, headers=csrf(client)).status_code == 403


# ---------- 카카오페이 ----------

@pytest.fixture
def kakao(monkeypatch):
    calls = []

    def fake(path, payload):
        calls.append((path, payload))
        if path.endswith("/ready"):
            tid = f"T{len(calls):010d}"
            return {"tid": tid, "next_redirect_pc_url": f"https://online-pay.kakao.com/mockup/{tid}"}
        if path.endswith("/approve"):
            amount = fake.approve_amount or Payment.query.filter_by(pg_tid=payload["tid"]).one().amount
            return {"aid": "A1", "tid": payload["tid"], "amount": {"total": amount}}
        if path.endswith("/cancel"):
            return {"status": "CANCEL_PAYMENT"}
        raise AssertionError(path)
    fake.approve_amount = None
    monkeypatch.setattr(kakaopay, "_post", fake)
    return fake, calls


def test_kakaopay_ready_and_approve(client, kakao):
    fake, calls = kakao
    login(client, "alice@test.local")
    assert client.get("/api/payments/methods").json["data"]["kakaopay"] is True
    inv = Invoice.query.filter_by(user_id=_alice().id, status="UNPAID").first()
    res = client.post("/api/payments/kakaopay/ready", json={"invoice_id": inv.id, "amount": 1}, headers=idem(client))
    assert res.status_code == 201 and res.json["data"]["redirect_url"].startswith("https://online-pay.kakao.com/")
    ready = calls[0][1]
    assert ready["total_amount"] == inv.amount and ready["cid"] == "TC0ONETIME"  # 요청의 amount 는 무시
    assert ready["approval_url"].startswith("http://localhost:5173/billing/kakaopay/approve?payment_id=")
    pid = res.json["data"]["payment"]["id"]
    ok = client.post("/api/payments/kakaopay/approve", json={"payment_id": pid, "pg_token": "abc123"}, headers=csrf(client))
    assert ok.json["data"]["payment"]["status"] == "SUCCEEDED"
    db.session.refresh(inv)
    assert inv.status == "PAID"
    assert PointTransaction.query.filter_by(business_ref=f"payment:{pid}").one().amount == inv.amount // 100
    # 새로고침으로 다시 와도 같은 결과
    assert client.post("/api/payments/kakaopay/approve", json={"payment_id": pid, "pg_token": "abc123"},
                       headers=csrf(client)).json["data"]["payment"]["status"] == "SUCCEEDED"


def test_kakaopay_amount_mismatch_cancels(client, kakao):
    fake, calls = kakao
    fake.approve_amount = 1
    login(client, "alice@test.local")
    inv = Invoice.query.filter_by(user_id=_alice().id, status="UNPAID").first()
    pid = client.post("/api/payments/kakaopay/ready", json={"invoice_id": inv.id}, headers=idem(client)).json["data"]["payment"]["id"]
    res = client.post("/api/payments/kakaopay/approve", json={"payment_id": pid, "pg_token": "abc"}, headers=csrf(client))
    assert res.status_code == 422 and calls[-1][0].endswith("/cancel")
    db.session.refresh(inv)
    assert inv.status == "UNPAID"


def test_kakaopay_other_users_payment_and_bad_token(client, kakao):
    login(client, "alice@test.local")
    inv = Invoice.query.filter_by(user_id=_alice().id, status="UNPAID").first()
    pid = client.post("/api/payments/kakaopay/ready", json={"invoice_id": inv.id}, headers=idem(client)).json["data"]["payment"]["id"]
    assert client.post("/api/payments/kakaopay/approve", json={"payment_id": pid, "pg_token": "bad token!"},
                       headers=csrf(client)).status_code == 422
    client.post("/api/auth/logout", headers=csrf(client))
    login(client, "bob@test.local")
    assert client.post("/api/payments/kakaopay/approve", json={"payment_id": pid, "pg_token": "abc"},
                       headers=csrf(client)).status_code == 404  # 남의 결제


def test_kakaopay_abort_and_refund(client, kakao):
    fake, calls = kakao
    login(client, "alice@test.local")
    inv = Invoice.query.filter_by(user_id=_alice().id, status="UNPAID").first()
    pid = client.post("/api/payments/kakaopay/ready", json={"invoice_id": inv.id}, headers=idem(client)).json["data"]["payment"]["id"]
    assert client.post("/api/payments/kakaopay/abort", json={"payment_id": pid, "reason": "cancel"},
                       headers=csrf(client)).json["data"]["payment"]["status"] == "CANCELED"
    pid2 = client.post("/api/payments/kakaopay/ready", json={"invoice_id": inv.id}, headers=idem(client)).json["data"]["payment"]["id"]
    client.post("/api/payments/kakaopay/approve", json={"payment_id": pid2, "pg_token": "tok"}, headers=csrf(client))
    client.post("/api/auth/logout", headers=csrf(client))
    login(client, "admin@test.local")
    res = client.post(f"/api/admin/payments/{pid2}/refund", json={"reason": "테스트 환불"}, headers=csrf(client))
    assert res.status_code == 200 and calls[-1][0].endswith("/cancel")


def test_kakaopay_disabled(client, app):
    app.config["KAKAOPAY_SECRET_KEY"] = ""
    login(client, "alice@test.local")
    assert client.get("/api/payments/methods").json["data"]["kakaopay"] is False
    assert client.post("/api/payments/kakaopay/ready", json={"invoice_id": 1}, headers=idem(client)).status_code == 503
