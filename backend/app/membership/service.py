"""멤버십 포인트 처리 (docs/contracts/membership-api.md)

- 잔액 변경과 원장(point_transactions) 기록은 한 트랜잭션
- 원장 business_ref UNIQUE → 같은 업무(결제 적립·혜택 사용)가 두 번 반영되지 않음
- 혜택 비용·등급·자격은 서버가 판단, 계정 행은 잠그고(SELECT ... FOR UPDATE) 갱신
"""
from sqlalchemy import func
from sqlalchemy.exc import IntegrityError
from sqlalchemy.orm.exc import StaleDataError

from ..core.errors import ApiError
from ..core.logging import security_event
from ..core.validation import idempotency_conflict, request_hash
from ..extensions import db
from ..models import Benefit, BenefitRedemption, MembershipAccount, MembershipTier, PointTransaction
from ..models.base import utcnow
from ..plans.routes import my_active_subscription

WELCOME_POINTS = 1000


def payment_points(account: MembershipAccount, amount: int) -> int:
    """요금 납부 적립 포인트 — 등급별 적립률(earn_rate_bp, 100 = 1%). 소수점 이하는 버린다."""
    rate = account.tier.earn_rate_bp if account and account.tier else 0
    return amount * rate // 10000


def tier_for_fee(monthly_fee: int):
    return (MembershipTier.query.filter(MembershipTier.min_monthly_fee <= monthly_fee)
            .order_by(MembershipTier.rank.desc()).first())


def locked_account(user_id: int):
    return MembershipAccount.query.filter_by(user_id=user_id).with_for_update().first()


def add_points(account: MembershipAccount, amount: int, kind: str, memo: str, business_ref: str, redemption_id=None):
    """잔액과 원장을 함께 바꾼다. commit 은 호출한 쪽에서 (하나의 트랜잭션)."""
    account.point_balance += amount
    if account.point_balance < 0:
        raise ApiError("INSUFFICIENT_POINTS", "포인트가 부족합니다.", 409)
    db.session.add(PointTransaction(account_id=account.id, amount=amount, balance_after=account.point_balance,
                                    kind=kind, memo=memo, business_ref=business_ref, redemption_id=redemption_id))


def join(user) -> MembershipAccount:
    if MembershipAccount.query.filter_by(user_id=user.id).first():
        raise ApiError("ALREADY_MEMBER", "이미 L∞P+ 회원입니다.", 409)
    sub = my_active_subscription(user.id)
    tier = tier_for_fee(sub.plan.monthly_fee if sub else 0)
    if tier is None:
        raise ApiError("NOT_READY", "멤버십 등급 정보가 없습니다.", 503)
    account = MembershipAccount(user_id=user.id, tier_id=tier.id, point_balance=0)
    db.session.add(account)
    try:
        db.session.flush()
        add_points(account, WELCOME_POINTS, "EARN", "가입 축하 포인트", f"welcome:{user.id}")
        db.session.commit()
    except IntegrityError:  # 가입 버튼 연타 → user_id·business_ref UNIQUE 가 막아 줌
        db.session.rollback()
        raise ApiError("ALREADY_MEMBER", "이미 L∞P+ 회원입니다.", 409)
    return account


def _month_start():
    return utcnow().replace(day=1, hour=0, minute=0, second=0, microsecond=0)


def used_this_month(user_id: int, benefit_id: int) -> int:
    return (db.session.query(func.count(BenefitRedemption.id))
            .filter(BenefitRedemption.user_id == user_id, BenefitRedemption.benefit_id == benefit_id,
                    BenefitRedemption.status == "USED", BenefitRedemption.created_at >= _month_start())
            .scalar())


def _denied(user, benefit_id, reason, code, message, status):
    security_event("membership.redeem.denied", "low", "혜택 사용 거부", user_id=user.id,
                   benefit_id=benefit_id, reason=reason)
    return ApiError(code, message, status)


def redeem(user, benefit_id: int, key: str):
    """혜택 사용. 반환: (redemption, created). 같은 키·같은 내용 → 기존 결과, 다른 내용 → 409."""
    req_hash = request_hash("membership.redeem", {"benefit_id": benefit_id})
    existing = BenefitRedemption.query.filter_by(user_id=user.id, idempotency_key=key).first()
    if existing:
        if existing.request_hash != req_hash:
            raise idempotency_conflict()
        return existing, False

    account = locked_account(user.id)
    if account is None:
        raise _denied(user, benefit_id, "not_member", "NOT_MEMBER", "L∞P+ 회원만 혜택을 사용할 수 있습니다.", 403)
    benefit = db.session.get(Benefit, benefit_id)
    if benefit is None or not benefit.is_active:
        raise ApiError("NOT_FOUND", "혜택을 찾을 수 없습니다.", 404)
    if account.tier.rank < benefit.min_tier_rank:
        raise _denied(user, benefit_id, "tier_too_low", "TIER_TOO_LOW", "현재 등급에서는 사용할 수 없는 혜택입니다.", 403)
    if used_this_month(user.id, benefit.id) >= benefit.monthly_limit:
        raise _denied(user, benefit_id, "monthly_limit", "LIMIT_REACHED", "이번 달 사용 횟수를 모두 썼습니다.", 409)
    if account.point_balance < benefit.required_points:
        raise _denied(user, benefit_id, "insufficient_points", "INSUFFICIENT_POINTS", "포인트가 부족합니다.", 409)

    redemption = BenefitRedemption(user_id=user.id, benefit_id=benefit.id, points_spent=benefit.required_points,
                                   idempotency_key=key, request_hash=req_hash)
    db.session.add(redemption)
    try:
        db.session.flush()
        add_points(account, -benefit.required_points, "REDEEM", benefit.name,
                   f"redemption:{redemption.id}", redemption.id)
        db.session.commit()  # version 컬럼: 그 사이 다른 요청이 잔액을 바꿨다면 실패
    except IntegrityError:
        db.session.rollback()  # 같은 키가 동시에 두 번 도착
        again = BenefitRedemption.query.filter_by(user_id=user.id, idempotency_key=key).one()
        if again.request_hash != req_hash:
            raise idempotency_conflict()
        return again, False
    except StaleDataError:
        db.session.rollback()
        raise ApiError("CONFLICT", "동시에 다른 요청이 처리되었습니다. 다시 시도하세요.", 409)
    return redemption, True
