"""7단계: L∞P+ 멤버십·포인트."""
from flask import Blueprint

from ..core.errors import ApiError, not_found, validation_error
from ..core.logging import app_log
from ..core.permissions import ROLE_ADMIN, current_user, login_required, roles_required
from ..core.responses import ok
from ..core.validation import body, idempotency_key, raise_if
from ..extensions import db
from ..models import Benefit, BenefitRedemption, MembershipAccount, MembershipTier, PointTransaction, User
from . import service
from .tiers import customer_rank, tier_dict, tier_name

bp = Blueprint("membership", __name__, url_prefix="/api/membership")


def _account_dict(account):
    if account is None:
        return {"joined": False}
    next_tier = (MembershipTier.query.filter(MembershipTier.rank > account.tier.rank, MembershipTier.rank < 3)
                 .order_by(MembershipTier.rank).first())
    return {
        "joined": True,
        "tier": tier_dict(account.tier),
        "tiers": [tier_dict(t) for t in MembershipTier.query.filter(MembershipTier.rank < 3).order_by(MembershipTier.rank).all()],
        "next_tier": None if not next_tier else {"name": tier_name(next_tier),
                                                  "min_monthly_fee": next_tier.min_monthly_fee},
        "point_balance": account.point_balance,
        "joined_at": account.created_at.isoformat() + "Z",
    }


def redemption_dict(r: BenefitRedemption):
    benefit = db.session.get(Benefit, r.benefit_id)
    return {"id": r.id, "code": f"LP{r.id:06d}", "benefit": benefit.name, "partner": benefit.partner,
            "points_spent": r.points_spent, "status": r.status, "created_at": r.created_at.isoformat() + "Z"}


@bp.get("/me")
@login_required
def me():
    account = MembershipAccount.query.filter_by(user_id=current_user().id).first()
    return ok({"membership": _account_dict(account)})


@bp.get("/tiers")
@login_required
def customer_tiers():
    return ok({"tiers": [tier_dict(t) for t in MembershipTier.query.filter(MembershipTier.rank < 3)
                         .order_by(MembershipTier.rank).all()]})


@bp.post("/join")
@login_required
def join():
    account = service.join(current_user())
    return ok({"membership": _account_dict(account)}, 201)


@bp.get("/transactions")
@login_required
def transactions():
    account = MembershipAccount.query.filter_by(user_id=current_user().id).first()
    if account is None:
        return ok({"transactions": []})
    rows = (PointTransaction.query.filter_by(account_id=account.id)
            .order_by(PointTransaction.id.desc()).limit(50).all())
    return ok({"transactions": [{"id": t.id, "amount": t.amount, "balance_after": t.balance_after,
                                 "kind": t.kind, "memo": t.memo,
                                 "created_at": t.created_at.isoformat() + "Z"} for t in rows]})


@bp.get("/benefits")
@login_required
def benefits():
    user = current_user()
    account = MembershipAccount.query.filter_by(user_id=user.id).first()
    items = []
    for b in Benefit.query.filter_by(is_active=True).order_by(Benefit.required_points).all():
        used = service.used_this_month(user.id, b.id)
        reason = None
        if account is None:
            reason = "L∞P+ 회원 전용"
        elif customer_rank(account.tier.rank) < customer_rank(b.min_tier_rank):
            tier = MembershipTier.query.filter_by(rank=b.min_tier_rank).first()
            reason = f"{tier_name(tier)} 등급 이상" if tier else "등급 정책 확인 필요"
        elif used >= b.monthly_limit:
            reason = "이번 달 사용 완료"
        elif account.point_balance < b.required_points:
            reason = "포인트 부족"
        items.append({"id": b.id, "name": b.name, "partner": b.partner, "required_points": b.required_points,
                      "monthly_limit": b.monthly_limit, "used_this_month": used,
                      "available": reason is None, "unavailable_reason": reason})
    return ok({"benefits": items})


@bp.get("/redemptions")
@login_required
def redemptions():
    rows = (BenefitRedemption.query.filter_by(user_id=current_user().id)
            .order_by(BenefitRedemption.id.desc()).limit(20).all())
    return ok({"redemptions": [redemption_dict(r) for r in rows]})


@bp.post("/benefits/<int:benefit_id>/redeem")
@login_required
def redeem(benefit_id):
    redemption, created = service.redeem(current_user(), benefit_id, idempotency_key())
    account = MembershipAccount.query.filter_by(user_id=current_user().id).first()
    return ok({"redemption": redemption_dict(redemption), "point_balance": account.point_balance,
               "replayed": not created}, 201 if created else 200)


# ---------- 멤버십 정책 관리 (ADMIN) — 잔액 직접 수정 API는 만들지 않는다 ----------

admin_bp = Blueprint("membership_admin", __name__, url_prefix="/api/admin/membership")


@admin_bp.get("/tiers")
@roles_required(ROLE_ADMIN)
def admin_tiers():
    return ok({"tiers": [tier_dict(t) for t in MembershipTier.query.filter(MembershipTier.rank < 3).order_by(MembershipTier.rank).all()]})


@admin_bp.patch("/customers/<int:user_id>/tier")
@roles_required(ROLE_ADMIN)
def admin_change_tier(user_id):
    from ..incidents.protection import audit
    from sqlalchemy.orm.exc import StaleDataError
    from sqlalchemy.exc import IntegrityError
    data = body()
    rank = data.get("rank")
    if isinstance(rank, bool) or not isinstance(rank, int) or rank not in range(3):
        raise validation_error({"rank": "등급은 0(일반유저), 1(Plus), 2(VIP) 중 하나여야 합니다. Admin은 관리자 역할입니다."})
    reason = data.get("reason")
    if not isinstance(reason, str) or not 1 <= len(reason.strip()) <= 300:
        raise validation_error({"reason": "변경 사유를 1~300자로 입력하세요."})
    user = db.session.get(User, user_id)
    if user is None or user.role != "CUSTOMER":
        raise not_found("고객 계정을 찾을 수 없습니다.")
    if not user.is_active:
        raise ApiError("INACTIVE_CUSTOMER", "탈퇴한 회원의 등급은 변경할 수 없습니다.", 409)
    tier = MembershipTier.query.filter_by(rank=rank).first()
    if tier is None:
        raise ApiError("NOT_READY", "멤버십 등급 정보가 없습니다.", 503)
    account = service.locked_account(user_id)
    before = account.tier.rank if account else None
    if account is None:
        # 관리자 지정은 포인트를 지급하거나 기존 가입 보너스를 재사용하지 않는다.
        account = MembershipAccount(user_id=user_id, tier_id=tier.id, point_balance=0)
        db.session.add(account)
    else:
        account.tier = tier
    audit("membership.tier.changed", "user", user_id, actor_type="ADMIN", actor_id=current_user().id,
          reason=f"rank {before} -> {rank}: {reason.strip()}")
    try:
        db.session.commit()
    except (StaleDataError, IntegrityError):
        db.session.rollback()
        raise ApiError("CONFLICT", "다른 요청이 처리되었습니다. 새로고침 후 다시 시도하세요.", 409)
    return ok({"membership": _account_dict(account)})


@admin_bp.get("/benefits")
@roles_required(ROLE_ADMIN)
def admin_benefits():
    return ok({"benefits": [b.to_dict() for b in Benefit.query.order_by(Benefit.id).all()]})


@admin_bp.patch("/benefits/<int:benefit_id>")
@roles_required(ROLE_ADMIN)
def admin_update_benefit(benefit_id):
    benefit = db.session.get(Benefit, benefit_id)
    if benefit is None:
        raise not_found("혜택을 찾을 수 없습니다.")
    data, errors = body(), {}
    if "is_active" in data:
        if not isinstance(data["is_active"], bool):
            errors["is_active"] = "true 또는 false 여야 합니다."
        else:
            benefit.is_active = data["is_active"]
    for key, low, high, label in (("required_points", 100, 1_000_000, "필요 포인트"),
                                  ("monthly_limit", 1, 31, "월 사용 횟수"),
                                  ("min_tier_rank", 0, 2, "최소 등급")):
        if key in data:
            value = data[key]
            if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
                errors[key] = f"{label}은(는) {low}~{high} 사이 정수여야 합니다."
            else:
                setattr(benefit, key, value)
    raise_if(errors)
    db.session.commit()
    app_log("membership.benefit.updated", admin_id=current_user().id, benefit_id=benefit.id)
    return ok({"benefit": benefit.to_dict()})
