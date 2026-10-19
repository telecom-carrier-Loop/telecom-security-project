"""모의 결제 (docs/contracts/payment-api.md). 실제 PG·카드 정보는 사용하지 않는다.

- 금액: invoices.amount 로만 결제. 요청에 다른 금액이 오면 거절 + payment.validation.failed
- 소유권: 남의 청구서는 404 + auth.object_access.denied
- 멱등: (user_id, idempotency_key) UNIQUE + 본문 해시. 같은 내용 → 같은 결과, 다른 내용 → 409
- 같은 청구서 중복 성공: 청구서 행 잠금 + 조건부 UPDATE + payments.success_invoice_id UNIQUE
- 포인트 적립: 원장 business_ref = payment:<id> UNIQUE
"""
from sqlalchemy import update
from sqlalchemy.exc import IntegrityError

from ..core.errors import ApiError, validation_error
from ..core.logging import app_log, security_event
from ..core.permissions import object_denied
from ..core.validation import idempotency_conflict, request_hash
from ..extensions import db
from ..membership.service import PAYMENT_EARN_RATE, add_points, locked_account
from ..models import Invoice, Payment, PaymentEvent, PointTransaction
from . import gateway

PAYABLE = ("UNPAID", "OVERDUE")


def _event(payment, event_type, from_status, to_status, detail=None):
    db.session.add(PaymentEvent(payment_id=payment.id, event_type=event_type,
                                from_status=from_status, to_status=to_status, detail=detail))


def pay(user, data: dict, key: str):
    # 본문 해시: 카드 번호 원문은 저장하지 않고 해시 계산에만 쓴다
    req_hash = request_hash("payment.create", {k: data.get(k) for k in ("invoice_id", "amount", "card_number")})
    replay = Payment.query.filter_by(user_id=user.id, idempotency_key=key).first()
    if replay:
        if replay.request_hash != req_hash:
            raise idempotency_conflict()
        return replay, False

    invoice_id = data.get("invoice_id")
    if not isinstance(invoice_id, int) or isinstance(invoice_id, bool):
        raise validation_error({"invoice_id": "청구서를 선택하세요."})

    invoice = Invoice.query.filter_by(id=invoice_id).with_for_update().first()  # 청구서 행 잠금
    if invoice is None or invoice.user_id != user.id:
        if invoice is not None:
            raise object_denied("invoice", invoice_id, "청구서를 찾을 수 없습니다.")
        raise ApiError("NOT_FOUND", "청구서를 찾을 수 없습니다.", 404)

    if "amount" in data and data.get("amount") != invoice.amount:
        security_event("payment.validation.failed", "high", "결제 금액 변조 의심", user_id=user.id,
                       invoice_id=invoice.id, requested_amount=data.get("amount"), expected_amount=invoice.amount)
        raise ApiError("AMOUNT_MISMATCH", "결제 금액이 청구 금액과 다릅니다.", 422)

    if invoice.status not in PAYABLE:
        security_event("payment.duplicate_request", "medium", "이미 납부된 청구서 결제 시도",
                       user_id=user.id, invoice_id=invoice.id)
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다.", 409)

    payment = Payment(user_id=user.id, invoice_id=invoice.id, amount=invoice.amount, idempotency_key=key,
                      request_hash=req_hash, transaction_ref=f"PENDING-{user.id}-{key}", status="PENDING")
    db.session.add(payment)
    try:
        db.session.flush()
    except IntegrityError:  # 같은 키가 동시에 도착
        db.session.rollback()
        again = Payment.query.filter_by(user_id=user.id, idempotency_key=key).one()
        if again.request_hash != req_hash:
            raise idempotency_conflict()
        return again, False
    _event(payment, "REQUESTED", None, "PENDING")

    result = gateway.charge(data.get("card_number"), invoice.amount)
    payment.transaction_ref = result.transaction_ref
    payment.method = f"MOCK_CARD_{result.card_last4}" if result.card_last4 else "MOCK_CARD"

    if not result.approved:
        payment.status = "FAILED"
        _event(payment, "FAILED", "PENDING", "FAILED", result.message)
        db.session.commit()
        app_log("payment.declined", user_id=user.id, payment_id=payment.id)
        return payment, True

    # 미납일 때만 납부로 → 서로 다른 키로 동시에 와도 하나만 성공
    claimed = db.session.execute(
        update(Invoice).where(Invoice.id == invoice.id, Invoice.status.in_(PAYABLE)).values(status="PAID")
    ).rowcount
    if claimed != 1:
        payment.status = "CANCELED"
        _event(payment, "CANCELED", "PENDING", "CANCELED", "동시 결제로 이미 납부됨 (모의 승인 취소)")
        db.session.commit()
        security_event("payment.duplicate_request", "medium", "동일 청구서 동시 결제", user_id=user.id,
                       invoice_id=invoice.id)
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다.", 409)

    payment.status = "SUCCEEDED"
    payment.success_invoice_id = invoice.id
    _event(payment, "APPROVED", "PENDING", "SUCCEEDED")
    account = locked_account(user.id)
    points = int(invoice.amount * PAYMENT_EARN_RATE)
    if account and points:
        add_points(account, points, "EARN", f"{invoice.period} 요금 납부 적립", f"payment:{payment.id}")
    try:
        db.session.commit()
    except IntegrityError:  # success_invoice_id UNIQUE — 최후 방어선
        db.session.rollback()
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다.", 409)
    return payment, True


def refund(payment: Payment, admin, reason: str) -> Payment:
    payment = Payment.query.filter_by(id=payment.id).with_for_update().one()
    if payment.status != "SUCCEEDED":
        raise ApiError("CONFLICT", "결제 완료 건만 환불할 수 있습니다.", 409)
    payment.status = "REFUNDED"
    payment.success_invoice_id = None
    invoice = db.session.get(Invoice, payment.invoice_id)
    invoice.status = "UNPAID"
    _event(payment, "REFUNDED", "SUCCEEDED", "REFUNDED", f"관리자 {admin.id}: {reason}")

    # 이 결제로 적립된 포인트를 되돌린다 (잔액이 모자라면 가능한 만큼만)
    earned = PointTransaction.query.filter_by(business_ref=f"payment:{payment.id}").first()
    if earned:
        account = locked_account(payment.user_id)
        back = min(earned.amount, account.point_balance)
        if back:
            add_points(account, -back, "REVERSE", f"{invoice.period} 납부 환불로 적립 취소",
                       f"payment-refund:{payment.id}")
    db.session.commit()
    app_log("payment.refunded", admin_id=admin.id, payment_id=payment.id)
    return payment
