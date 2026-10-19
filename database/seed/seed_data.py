"""합성 시드 데이터 (실제 고객정보 없음). 로컬·실습 DB에서만 사용한다.

실행: backend 폴더에서  python -m flask --app wsgi seed
테스트(backend/tests)도 같은 함수를 사용한다.
테스트 계정 비밀번호는 모두 TEST_PASSWORD.
"""
import hashlib
import json
from datetime import date, timedelta

from app.extensions import db
from app.models import (Benefit, IncidentHistory, Invoice, MembershipAccount, MembershipTier, Payment, Plan,
                        PointTransaction, SecurityIncident, Subscription, SupportTicket, UsageRecord, User)
from app.models.base import utcnow

TEST_PASSWORD = "Test1234!"


def _hash(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def seed_data():
    if Plan.query.first():
        return

    tiers = [MembershipTier(code=c, name=n, min_monthly_fee=f, rank=r) for c, n, f, r in [
        ("BASIC", "Basic", 0, 0), ("SILVER", "Silver", 35000, 1),
        ("GOLD", "Gold", 60000, 2), ("VIP", "VIP", 85000, 3)]]
    plans = [Plan(code=c, name=n, monthly_fee=f, data_mb=d, network=net) for c, n, f, d, net in [
        ("LTE_SLIM", "LTE 슬림", 25000, 6 * 1024, "LTE"),
        ("5G_BASIC", "5G Basic", 35000, 20 * 1024, "5G"),
        ("5G_STANDARD", "5G Standard", 55000, 110 * 1024, "5G"),
        ("5G_PREMIUM", "5G Premium", 85000, -1, "5G")]]
    db.session.add_all(tiers + plans)
    db.session.add_all([
        Benefit(name="편의점 2,000원 할인", partner="가상편의점", required_points=2000, min_tier_rank=0),
        Benefit(name="영화 관람권", partner="가상시네마", required_points=9000, min_tier_rank=1),
        Benefit(name="카페 아메리카노", partner="가상카페", required_points=4500, min_tier_rank=1),
    ])
    db.session.flush()

    def make_user(email, name, role="CUSTOMER"):
        u = User(email=email, name=name, role=role, password_changed_at=utcnow())
        u.set_password(TEST_PASSWORD)
        db.session.add(u)
        db.session.flush()
        return u

    alice = make_user("alice@test.local", "김하늘")
    bob = make_user("bob@test.local", "이바다")
    sec = make_user("admin@test.local", "관리자", "ADMIN")  # 상담·보안 업무를 함께 보는 통합 관리자

    today = date.today()
    period = today.strftime("%Y-%m")
    for user, plan, phone, used, tier, points in [
        (alice, plans[1], "010-0000-1001", 8 * 1024, tiers[1], 12000),
        (bob, plans[2], "010-0000-1002", 31 * 1024, tiers[2], 3000),
    ]:
        sub = Subscription(user_id=user.id, plan_id=plan.id, phone_number=phone,
                           started_on=today - timedelta(days=200))
        db.session.add(sub)
        db.session.flush()
        db.session.add(UsageRecord(subscription_id=sub.id, period=period, data_used_mb=used, voice_used_minutes=120))
        acc = MembershipAccount(user_id=user.id, tier_id=tier.id, point_balance=points)
        db.session.add(acc)
        db.session.flush()
        db.session.add(PointTransaction(account_id=acc.id, amount=points, balance_after=points, kind="EARN",
                                        memo="가입 축하 포인트", business_ref=f"seed-welcome:{user.id}"))
        prev = today.replace(day=1) - timedelta(days=1)
        paid = Invoice(user_id=user.id, subscription_id=sub.id, period=prev.strftime("%Y-%m"),
                       amount=plan.monthly_fee, due_date=prev.replace(day=25), status="PAID")
        unpaid = Invoice(user_id=user.id, subscription_id=sub.id, period=period,
                         amount=plan.monthly_fee, due_date=today.replace(day=25), status="UNPAID")
        db.session.add_all([paid, unpaid])
        db.session.flush()
        db.session.add(Payment(user_id=user.id, invoice_id=paid.id, amount=paid.amount, status="SUCCEEDED",
                               transaction_ref=f"MOCK-SEED-{user.id}-{paid.period}", success_invoice_id=paid.id,
                               idempotency_key=f"seed-{user.id}-{paid.period}", request_hash=_hash(paid.id)))

    db.session.add(SupportTicket(user_id=alice.id, category="BILLING", title="이번 달 요금이 평소보다 높아요",
                                 content="부가서비스 내역을 확인하고 싶습니다."))

    for src, eid, etype, sev, title, status, assignee in [
        ("suricata", "sensor-c-01:seed-0001", "ids.suricata.alert", "high", "외부에서 DB 포트 접근 시도 탐지", "OPEN", None),
        ("flask-api", "seed-api:auth-0001", "auth.login.failed", "medium", "동일 계정 로그인 실패 반복", "INVESTIGATING", sec.id),
        ("zabbix", "seed-zbx:backup-0001", "infra.backup.failed", "low", "야간 백업 작업 실패", "RESOLVED", sec.id),
    ]:
        inc = SecurityIncident(source=src, event_id=eid, event_type=etype, severity=sev, title=title, status=status,
                               assigned_to=assignee, detected_at=utcnow(), event_hash=_hash([src, eid]),
                               asset_host="pc1", asset_service="telecom-api",
                               resolved_at=utcnow() if status == "RESOLVED" else None)
        db.session.add(inc)
        db.session.flush()
        db.session.add(IncidentHistory(incident_id=inc.id, action="CREATED", note=f"{src} 이벤트로 생성 (합성)"))
    db.session.commit()
