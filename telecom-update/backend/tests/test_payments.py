from app.extensions import db
from app.models import Invoice, MembershipAccount
from tests.conftest import csrf, login, logout

APPROVE, DECLINE = "4242424242424242", "4000000000000002"


def _unpaid(user_id):
    return Invoice.query.filter_by(user_id=user_id, status="UNPAID").one()


def _pay(client, body, key):
    return client.post("/api/payments", json=body, headers=csrf(client, **{"Idempotency-Key": key}))


def _points(uid):
    return MembershipAccount.query.filter_by(user_id=uid).one().point_balance


def test_success_marks_invoice_and_earns_points(client):
    login(client, "alice@test.local")
    inv = _unpaid(1)
    p = _pay(client, {"invoice_id": inv.id, "card_number": APPROVE}, "pay-ok-000001").json["data"]["payment"]
    assert p["status"] == "SUCCEEDED" and p["amount"] == 35000
    assert [e["type"] for e in p["events"]] == ["REQUESTED", "APPROVED"]
    assert db.session.get(Invoice, inv.id).status == "PAID" and _points(1) == 12350


def test_declined(client):
    login(client, "alice@test.local")
    inv = _unpaid(1)
    assert _pay(client, {"invoice_id": inv.id, "card_number": DECLINE}, "pay-no-000001").json["data"]["payment"]["status"] == "FAILED"
    assert db.session.get(Invoice, inv.id).status == "UNPAID"


def test_tampered_amount_422(client):
    login(client, "alice@test.local")
    res = _pay(client, {"invoice_id": _unpaid(1).id, "amount": 1000, "card_number": APPROVE}, "pay-tamper-01")
    assert res.status_code == 422 and res.json["error"]["code"] == "AMOUNT_MISMATCH"


def test_others_invoice_404(client):
    login(client, "alice@test.local")
    assert _pay(client, {"invoice_id": _unpaid(2).id, "card_number": APPROVE}, "pay-idor-0001").status_code == 404


def test_same_key_same_body_charged_once(client):
    login(client, "alice@test.local")
    body = {"invoice_id": _unpaid(1).id, "card_number": APPROVE}
    first, second = _pay(client, body, "pay-dup-00001"), _pay(client, body, "pay-dup-00001")
    assert first.status_code == 201 and second.status_code == 200 and second.json["data"]["replayed"] is True
    assert first.json["data"]["payment"]["id"] == second.json["data"]["payment"]["id"] and _points(1) == 12350


def test_same_key_different_body_409(client):
    login(client, "alice@test.local")
    inv_id = _unpaid(1).id
    _pay(client, {"invoice_id": inv_id, "card_number": DECLINE}, "pay-diff-0001")
    res = _pay(client, {"invoice_id": inv_id, "card_number": APPROVE}, "pay-diff-0001")
    assert res.status_code == 409 and res.json["error"]["code"] == "IDEMPOTENCY_CONFLICT"


def test_different_keys_cannot_pay_twice(client):
    login(client, "alice@test.local")
    inv_id = _unpaid(1).id
    _pay(client, {"invoice_id": inv_id, "card_number": APPROVE}, "pay-a-0000001")
    res = _pay(client, {"invoice_id": inv_id, "card_number": APPROVE}, "pay-b-0000001")
    assert res.status_code == 409 and res.json["error"]["code"] == "ALREADY_PAID" and _points(1) == 12350


def test_refund_by_support_admin_reverses_points(client):
    login(client, "alice@test.local")
    inv_id = _unpaid(1).id
    pid = _pay(client, {"invoice_id": inv_id, "card_number": APPROVE}, "pay-ref-00001").json["data"]["payment"]["id"]
    assert client.post(f"/api/admin/payments/{pid}/refund", json={"reason": "셀프"}, headers=csrf(client)).status_code == 403
    logout(client)
    login(client, "admin@test.local")
    res = client.post(f"/api/admin/payments/{pid}/refund", json={"reason": "중복 청구 확인"}, headers=csrf(client))
    assert res.json["data"]["payment"]["status"] == "REFUNDED"
    assert db.session.get(Invoice, inv_id).status == "UNPAID" and _points(1) == 12000
    assert client.post(f"/api/admin/payments/{pid}/refund", json={"reason": "다시"}, headers=csrf(client)).status_code == 409
    logout(client)
    login(client, "alice@test.local")  # 환불 후 다시 결제 가능
    assert _pay(client, {"invoice_id": inv_id, "card_number": APPROVE}, "pay-again-001").status_code == 201
