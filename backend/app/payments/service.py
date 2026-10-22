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
from ..membership.service import add_points, locked_account, payment_points
from ..models import Invoice, Payment, PaymentEvent, PointTransaction
import re

from . import gateway, kakaopay

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

    _mark_succeeded(payment, invoice, user.id)
    try:
        db.session.commit()
    except IntegrityError:  # success_invoice_id UNIQUE — 최후 방어선
        db.session.rollback()
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다.", 409)
    return payment, True


def _mark_succeeded(payment, invoice, user_id, detail=None):
    """결제 성공 처리 공통 (모의 카드·카카오페이). 청구서는 호출한 쪽이 PAID 로 선점한 상태."""
    payment.status = "SUCCEEDED"
    payment.success_invoice_id = invoice.id
    _event(payment, "APPROVED", "PENDING", "SUCCEEDED", detail)
    account = locked_account(user_id)
    points = payment_points(account, invoice.amount)
    if account and points:
        add_points(account, points, "EARN", f"{invoice.period} 요금 납부 적립 ({account.tier.name} {account.tier.earn_rate_bp / 100:g}%)",
                   f"payment:{payment.id}")


def refund(payment: Payment, admin, reason: str) -> Payment:
    payment = Payment.query.filter_by(id=payment.id).with_for_update().one()
    if payment.status != "SUCCEEDED":
        raise ApiError("CONFLICT", "결제 완료 건만 환불할 수 있습니다.", 409)
    if payment.method == "KAKAOPAY":  # 카카오페이 결제는 카카오페이에서 먼저 취소
        try:
            kakaopay.cancel(payment.pg_tid, payment.amount)
        except kakaopay.KakaoPayError as err:
            db.session.rollback()
            raise ApiError("PG_ERROR", f"카카오페이 취소 실패: {err}", 502)
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


# ---------- 카카오페이 테스트 결제 ----------

PG_TOKEN_RE = re.compile(r"^[A-Za-z0-9]{1,64}$")


def _my_invoice_locked(user, invoice_id):
    if not isinstance(invoice_id, int) or isinstance(invoice_id, bool):
        raise validation_error({"invoice_id": "청구서를 선택하세요."})
    invoice = Invoice.query.filter_by(id=invoice_id).with_for_update().first()
    if invoice is None or invoice.user_id != user.id:
        if invoice is not None:
            raise object_denied("invoice", invoice_id, "청구서를 찾을 수 없습니다.")
        raise ApiError("NOT_FOUND", "청구서를 찾을 수 없습니다.", 404)
    return invoice


def _my_kakao_payment(user, payment_id):
    if not isinstance(payment_id, int) or isinstance(payment_id, bool):
        raise validation_error({"payment_id": "결제 ID가 필요합니다."})
    payment = Payment.query.filter_by(id=payment_id).with_for_update().first()
    if payment is None or payment.user_id != user.id or payment.method != "KAKAOPAY":
        if payment is not None and payment.user_id != user.id:
            raise object_denied("payment", payment_id, "결제를 찾을 수 없습니다.")
        raise ApiError("NOT_FOUND", "결제를 찾을 수 없습니다.", 404)
    return payment


def kakaopay_ready(user, data: dict, key: str):
    """결제 준비 → 카카오페이 결제 화면 주소를 돌려준다."""
    if not kakaopay.enabled():
        raise ApiError("PG_DISABLED", "카카오페이 테스트 결제가 설정되지 않았습니다.", 503)
    req_hash = request_hash("payment.kakaopay.ready", {"invoice_id": data.get("invoice_id")})
    replay = Payment.query.filter_by(user_id=user.id, idempotency_key=key).first()
    if replay:
        if replay.request_hash != req_hash:
            raise idempotency_conflict()
        redirect = PaymentEvent.query.filter_by(payment_id=replay.id, event_type="REQUESTED").first()
        return replay, (redirect.detail if redirect else None), False

    invoice = _my_invoice_locked(user, data.get("invoice_id"))
    if invoice.status not in PAYABLE:
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다.", 409)
    payment = Payment(user_id=user.id, invoice_id=invoice.id, amount=invoice.amount, idempotency_key=key,
                      request_hash=req_hash, transaction_ref=f"KAKAO-PENDING-{user.id}-{key}"[:64],
                      method="KAKAOPAY", status="PENDING")
    db.session.add(payment)
    try:
        db.session.flush()
    except IntegrityError:
        db.session.rollback()
        raise idempotency_conflict()
    try:
        res = kakaopay.ready(payment.id, user.id, f"L∞P {invoice.period} 통신요금", invoice.amount)
    except kakaopay.KakaoPayError as err:
        payment.status = "FAILED"
        _event(payment, "FAILED", "PENDING", "FAILED", f"ready 실패: {err}"[:255])
        db.session.commit()
        raise ApiError("PG_ERROR", f"카카오페이 결제 준비에 실패했습니다: {err}", 502)
    tid = str(res.get("tid") or "")
    redirect = res.get("next_redirect_pc_url") or res.get("next_redirect_mobile_url")
    if not tid or not redirect:
        payment.status = "FAILED"
        _event(payment, "FAILED", "PENDING", "FAILED", "ready 응답에 tid/redirect 없음")
        db.session.commit()
        raise ApiError("PG_ERROR", "카카오페이 응답이 올바르지 않습니다.", 502)
    payment.pg_tid = tid[:64]
    payment.transaction_ref = f"KAKAO-{tid}"[:64]
    _event(payment, "REQUESTED", None, "PENDING", redirect[:255])
    db.session.commit()
    app_log("payment.kakaopay.ready", user_id=user.id, payment_id=payment.id)
    return payment, redirect, True


def kakaopay_approve(user, data: dict):
    """카카오페이 인증 후 돌아온 pg_token 으로 승인."""
    payment = _my_kakao_payment(user, data.get("payment_id"))
    pg_token = str(data.get("pg_token") or "")
    if not PG_TOKEN_RE.match(pg_token):
        raise validation_error({"pg_token": "pg_token 형식이 올바르지 않습니다."})
    if payment.status == "SUCCEEDED":
        return payment  # 새로고침 등으로 다시 와도 같은 결과
    if payment.status != "PENDING" or not payment.pg_tid:
        raise ApiError("CONFLICT", "승인할 수 없는 결제 상태입니다.", 409)
    invoice = Invoice.query.filter_by(id=payment.invoice_id).with_for_update().one()
    try:
        res = kakaopay.approve(payment.pg_tid, payment.id, user.id, pg_token)
    except kakaopay.KakaoPayError as err:
        payment.status = "FAILED"
        _event(payment, "FAILED", "PENDING", "FAILED", f"approve 실패: {err}"[:255])
        db.session.commit()
        raise ApiError("PG_ERROR", f"카카오페이 승인에 실패했습니다: {err}", 502)
    approved_total = (res.get("amount") or {}).get("total")
    if approved_total != payment.amount:  # 승인 금액이 청구 금액과 다르면 즉시 취소
        security_event("payment.validation.failed", "high", "카카오페이 승인 금액 불일치", user_id=user.id,
                       payment_id=payment.id, approved_amount=approved_total, expected_amount=payment.amount)
        try:
            kakaopay.cancel(payment.pg_tid, approved_total or payment.amount)
        except kakaopay.KakaoPayError:
            pass
        payment.status = "FAILED"
        _event(payment, "FAILED", "PENDING", "FAILED", "승인 금액 불일치 → 취소")
        db.session.commit()
        raise ApiError("AMOUNT_MISMATCH", "승인 금액이 청구 금액과 달라 결제를 취소했습니다.", 422)
    claimed = db.session.execute(
        update(Invoice).where(Invoice.id == invoice.id, Invoice.status.in_(PAYABLE)).values(status="PAID")
    ).rowcount
    if claimed != 1:  # 그사이 다른 방법으로 납부됨 → 카카오페이 승인 취소
        try:
            kakaopay.cancel(payment.pg_tid, payment.amount)
        except kakaopay.KakaoPayError:
            pass
        payment.status = "CANCELED"
        _event(payment, "CANCELED", "PENDING", "CANCELED", "이미 납부된 청구서 → 카카오페이 승인 취소")
        db.session.commit()
        security_event("payment.duplicate_request", "medium", "동일 청구서 중복 결제(카카오페이)", user_id=user.id,
                       invoice_id=invoice.id)
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다. 카카오페이 결제는 취소했습니다.", 409)
    _mark_succeeded(payment, invoice, user.id, f"kakaopay aid={str(res.get('aid') or '')[:40]}")
    try:
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        raise ApiError("ALREADY_PAID", "이미 납부한 청구서입니다.", 409)
    app_log("payment.kakaopay.approved", user_id=user.id, payment_id=payment.id)
    return payment


def kakaopay_abort(user, data: dict):
    """사용자가 카카오페이 화면에서 취소했거나 실패해서 돌아온 경우."""
    payment = _my_kakao_payment(user, data.get("payment_id"))
    reason = "CANCELED" if data.get("reason") == "cancel" else "FAILED"
    if payment.status == "PENDING":
        payment.status = reason
        _event(payment, reason, "PENDING", reason, "사용자 취소" if reason == "CANCELED" else "카카오페이 결제 실패")
        db.session.commit()
    return payment
