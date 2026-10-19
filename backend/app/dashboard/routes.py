"""고객 대시보드 요약. 모든 조회 기준은 토큰의 사용자 → 다른 고객 데이터는 구조적으로 나올 수 없음."""
from flask import Blueprint

from ..core.permissions import current_user, login_required
from ..core.responses import ok
from ..models import Invoice, MembershipAccount, Payment, SupportTicket, UsageRecord
from ..plans.routes import my_active_subscription, usage_dict

bp = Blueprint("dashboard", __name__, url_prefix="/api/dashboard")


@bp.get("/summary")
@login_required
def summary():
    user = current_user()
    sub = my_active_subscription(user.id)

    usage = None
    if sub:
        record = (UsageRecord.query.filter_by(subscription_id=sub.id)
                  .order_by(UsageRecord.period.desc()).first())
        usage = usage_dict(sub, record)

    unpaid = (Invoice.query.filter(Invoice.user_id == user.id,
                                   Invoice.status.in_(("UNPAID", "OVERDUE")))
              .order_by(Invoice.due_date).all())
    membership = MembershipAccount.query.filter_by(user_id=user.id).first()
    tickets = (SupportTicket.query.filter_by(user_id=user.id)
               .order_by(SupportTicket.created_at.desc()).limit(3).all())
    payments = (Payment.query.filter_by(user_id=user.id)
                .order_by(Payment.created_at.desc()).limit(3).all())

    return ok({
        "user": user.to_profile(),
        "subscription": None if not sub else {
            "phone_number": sub.phone_number, "plan": sub.plan.to_dict(),
        },
        "usage": usage,
        "billing": {
            "amount_due": sum(i.amount for i in unpaid),
            "next_due_date": unpaid[0].due_date.isoformat() if unpaid else None,
            "unpaid_invoices": [i.to_dict() for i in unpaid],
        },
        "membership": None if not membership else {
            "tier": membership.tier.name, "tier_code": membership.tier.code,
            "point_balance": membership.point_balance,
        },
        "recent_tickets": [{"id": t.id, "title": t.title, "status": t.status,
                            "created_at": t.created_at.isoformat() + "Z"} for t in tickets],
        "recent_payments": [p.to_dict() for p in payments],
    })
