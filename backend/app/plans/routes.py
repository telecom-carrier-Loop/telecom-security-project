from flask import Blueprint

from ..core.permissions import current_user, login_required
from ..core.responses import ok
from ..models import Plan, Subscription, UsageRecord

bp = Blueprint("plans", __name__, url_prefix="/api")


@bp.get("/plans")
def list_plans():
    plans = Plan.query.filter_by(is_active=True).order_by(Plan.monthly_fee).all()
    return ok({"plans": [p.to_dict() for p in plans]})


def my_active_subscription(user_id: int):
    return (Subscription.query
            .filter_by(user_id=user_id, status="ACTIVE")
            .order_by(Subscription.id.desc()).first())


@bp.get("/subscriptions/me")
@login_required
def my_subscription():
    sub = my_active_subscription(current_user().id)
    if not sub:
        return ok({"subscription": None})
    return ok({"subscription": {
        "id": sub.id, "phone_number": sub.phone_number, "status": sub.status,
        "started_on": sub.started_on.isoformat(), "plan": sub.plan.to_dict(),
    }})


@bp.get("/usage/me")
@login_required
def my_usage():
    sub = my_active_subscription(current_user().id)
    if not sub:
        return ok({"usage": None})
    record = (UsageRecord.query.filter_by(subscription_id=sub.id)
              .order_by(UsageRecord.period.desc()).first())
    return ok({"usage": usage_dict(sub, record)})


def usage_dict(sub, record):
    if not record:
        return None
    return {
        "period": record.period,
        "data_used_mb": record.data_used_mb,
        "data_limit_mb": sub.plan.data_mb,
        "voice_used_minutes": record.voice_used_minutes,
        "voice_limit_minutes": sub.plan.voice_minutes,
    }
