"""8단계: 청구서·모의 결제."""
from flask import Blueprint

from ..core.errors import ApiError
from ..core.permissions import ROLE_ADMIN, current_user, login_required, object_denied, roles_required
from ..core.responses import ok
from ..core.validation import body, idempotency_key, raise_if, text
from ..extensions import db
from ..models import Invoice, Payment, PaymentEvent, User
from . import gateway, service

bp = Blueprint("payments", __name__, url_prefix="/api")


def payment_dict(p: Payment, with_events=False) -> dict:
    data = p.to_dict()
    invoice = db.session.get(Invoice, p.invoice_id)
    data.update({"period": invoice.period, "transaction_ref": p.transaction_ref})
    if with_events:
        events = PaymentEvent.query.filter_by(payment_id=p.id).order_by(PaymentEvent.id).all()
        data["events"] = [{"type": e.event_type, "to_status": e.to_status, "detail": e.detail,
                           "at": e.created_at.isoformat() + "Z"} for e in events]
    return data


@bp.get("/payments/test-cards")
def test_cards():
    labels = {"4242424242424242": "승인", "4000000000000002": "거절 (카드사)", "4000000000009995": "거절 (잔액 부족)"}
    return ok({"cards": [{"number": n, "result": labels[n]} for n in gateway.TEST_CARDS]})


@bp.get("/invoices/me")
@login_required
def my_invoices():
    rows = (Invoice.query.filter_by(user_id=current_user().id)
            .order_by(Invoice.period.desc()).all())
    return ok({"invoices": [i.to_dict() for i in rows]})


@bp.get("/payments/me")
@login_required
def my_payments():
    rows = (Payment.query.filter_by(user_id=current_user().id)
            .order_by(Payment.id.desc()).limit(50).all())
    return ok({"payments": [payment_dict(p) for p in rows]})


@bp.post("/payments")
@login_required
def create_payment():
    payment, created = service.pay(current_user(), body(), idempotency_key())
    return ok({"payment": payment_dict(payment, with_events=True), "replayed": not created},
              201 if created else 200)


@bp.get("/payments/<int:payment_id>")
@login_required
def get_payment(payment_id):
    payment = db.session.get(Payment, payment_id)
    if payment is None:
        raise ApiError("NOT_FOUND", "결제를 찾을 수 없습니다.", 404)
    if payment.user_id != current_user().id:
        raise object_denied("payment", payment_id, "결제를 찾을 수 없습니다.")
    return ok({"payment": payment_dict(payment, with_events=True)})


# ---------- 상담(결제) 관리자 ----------

@bp.get("/admin/payments")
@roles_required(ROLE_ADMIN)
def admin_payments():
    rows = Payment.query.order_by(Payment.id.desc()).limit(100).all()
    out = []
    for p in rows:
        d = payment_dict(p)
        d["customer_name"] = db.session.get(User, p.user_id).name
        out.append(d)
    return ok({"payments": out})


@bp.post("/admin/payments/<int:payment_id>/refund")
@roles_required(ROLE_ADMIN)
def admin_refund(payment_id):
    payment = db.session.get(Payment, payment_id)
    if payment is None:
        raise ApiError("NOT_FOUND", "결제를 찾을 수 없습니다.", 404)
    errors: dict = {}
    reason = text(body(), "reason", "환불 사유", 2, 200, errors)
    raise_if(errors)
    return ok({"payment": payment_dict(service.refund(payment, current_user(), reason), with_events=True)})
