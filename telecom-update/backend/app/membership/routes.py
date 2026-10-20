"""7단계: L∞P+ 멤버십·포인트."""
from flask import Blueprint

from ..core.errors import not_found
from ..core.logging import app_log
from ..core.permissions import ROLE_ADMIN, current_user, login_required, roles_required
from ..core.responses import ok
from ..core.validation import body, idempotency_key, raise_if
from ..extensions import db
from ..models import Benefit, BenefitRedemption, MembershipAccount, MembershipTier, PointTransaction
from . import service

bp = Blueprint("membership", __name__, url_prefix="/api/membership")


def _account_dict(account):
    if account is None:
        return {"joined": False}
    next_tier = (MembershipTier.query.filter(MembershipTier.rank > account.tier.rank)
                 .order_by(MembershipTier.rank).first())
    return {
        "joined": True,
        "tier": {"code": account.tier.code, "name": account.tier.name, "rank": account.tier.rank},
        "next_tier": None if not next_tier else {"name": next_tier.name,
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
        elif account.tier.rank < b.min_tier_rank:
            tier = MembershipTier.query.filter_by(rank=b.min_tier_rank).first()
            reason = f"{tier.name} 등급 이상"
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
                                  ("min_tier_rank", 0, 3, "최소 등급")):
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
