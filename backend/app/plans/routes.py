from datetime import date

from flask import Blueprint

from ..core.errors import ApiError, validation_error
from ..core.logging import app_log
from ..core.permissions import current_user, login_required
from ..core.responses import ok
from ..core.validation import body
from ..extensions import db
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


@bp.post("/subscriptions/me")
@login_required
def choose_plan():
    """요금제 가입(회선 없음) 또는 변경(회선 있음). 모의 처리이며 즉시 적용한다.

    요금은 서버의 plans 테이블 값만 사용하고, 고객만 사용할 수 있다.
    """
    user = current_user()
    if user.role != "CUSTOMER":
        raise ApiError("FORBIDDEN", "고객 계정만 요금제를 변경할 수 있습니다.", 403)
    plan_id = body().get("plan_id")
    plan = db.session.get(Plan, plan_id) if isinstance(plan_id, int) and not isinstance(plan_id, bool) else None
    if plan is None or not plan.is_active:
        raise validation_error({"plan_id": "선택할 수 없는 요금제입니다."})

    sub = my_active_subscription(user.id)
    if sub and sub.plan_id == plan.id:
        raise ApiError("SAME_PLAN", "이미 사용 중인 요금제입니다.", 409)
    if sub:
        before = sub.plan.name
        sub.plan_id = plan.id
        changed = "CHANGED"
    else:
        before = None
        sub = Subscription(user_id=user.id, plan_id=plan.id, status="ACTIVE",
                           phone_number=f"010-{9000 + user.id // 10000:04d}-{user.id % 10000:04d}",  # 가상 번호
                           started_on=date.today())
        db.session.add(sub)
        db.session.flush()
        db.session.add(UsageRecord(subscription_id=sub.id, period=date.today().strftime("%Y-%m")))
        changed = "CREATED"
    db.session.commit()
    app_log("plan.selected", user_id=user.id, plan_id=plan.id, result=changed)
    return ok({"result": changed, "previous_plan": before,
               "subscription": {"id": sub.id, "phone_number": sub.phone_number, "status": sub.status,
                                "started_on": sub.started_on.isoformat(), "plan": plan.to_dict()}},
              201 if changed == "CREATED" else 200)
