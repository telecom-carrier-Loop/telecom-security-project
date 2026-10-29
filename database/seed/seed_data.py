"""합성 시드 데이터 (실제 고객정보 없음). 로컬·실습 DB에서만 사용한다.

실행: backend 폴더에서  python -m flask --app wsgi seed
테스트(backend/tests)도 같은 함수를 사용한다.
테스트 계정 비밀번호는 모두 TEST_PASSWORD.
"""
import hashlib
import json
from datetime import date, timedelta

from app.extensions import db
from datetime import timedelta as _td

EARN_RATE_BP = {'BASIC': 50, 'SILVER': 100, 'GOLD': 200, 'VIP': 300}  # 등급별 납부 적립률 (100 = 1%)

from app.models import (Notice, ShopItem, Benefit, IncidentHistory, Invoice, IpBlock, IpWhitelist, MembershipAccount, MembershipTier,
                        Payment, Plan, PointTransaction, SecurityAuditLog, SecurityIncident, Subscription,
                        SupportTicket, UsageRecord, User)
from app.models.base import utcnow

TEST_PASSWORD = "Test1234!"


def _hash(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True).encode()).hexdigest()


def _shop_and_notices(admin_id=None):
    """포인트 상점 상품·공지사항 (가상)."""
    if not ShopItem.query.first():
        db.session.add_all([ShopItem(name=n, description=d, category=c, price_points=p, stock=s, min_tier_rank=r)
                            for n, d, c, p, s, r in [
            ("데이터 1GB 쿠폰", "이번 달 데이터 1GB 추가 (가상)", "DATA", 3000, None, 0),
            ("편의점 3,000원 상품권", "가상편의점 모바일 상품권", "COUPON", 3000, 100, 0),
            ("L∞P 텀블러", "L∞P 로고 텀블러 (가상 배송)", "GOODS", 8000, 20, 1),
            ("데이터 5GB 쿠폰", "이번 달 데이터 5GB 추가 (가상)", "DATA", 12000, None, 2),
            ("무선 이어폰", "VIP 전용 한정 상품 (가상)", "GOODS", 50000, 3, 3),
            ("데이터 500MB 쿠폰", "이번 달 데이터 500MB 추가 (가상)", "DATA", 1500, None, 0),
            ("음성통화 30분 추가", "이번 달 음성통화 30분 추가 (가상)", "DATA", 2000, None, 0),
            ("카페 아메리카노 교환권", "가상카페 아메리카노 1잔 모바일 교환권", "COUPON", 4500, 200, 0),
            ("영화 관람권 1매", "가상시네마 2D 일반 관람권", "COUPON", 9000, 50, 1),
            ("L∞P 에코백", "L∞P 로고 캔버스 에코백 (가상 배송)", "GOODS", 6000, 30, 1),
            ("보조배터리 10000mAh", "L∞P 로고 보조배터리 (가상 배송)", "GOODS", 25000, 10, 2),
            ("데이터 무제한 1일 이용권", "24시간 데이터 무제한 (가상, VIP 전용)", "DATA", 20000, None, 3),
        ]])
    if not Notice.query.first():
        now = utcnow()
        db.session.add_all([Notice(category=c, title=t, content=b, is_pinned=p, is_published=True,
                                   published_at=now, author_id=admin_id) for c, t, b, p in [
            ("SECURITY", "[보안] L∞P를 사칭한 문자에 주의하세요",
             "L∞P는 문자로 비밀번호나 카드 번호를 묻지 않습니다.\n의심 문자를 받으면 링크를 누르지 말고 1:1 문의로 알려 주세요.", True),
            ("MAINTENANCE", "10월 정기 점검 안내 (새벽 2시~4시)",
             "점검 시간 동안 요금 납부와 멤버십 기능을 잠시 사용할 수 없습니다.", False),
            ("EVENT", "L∞P+ 포인트 상점 오픈",
             "등급별로 다른 상품을 포인트로 교환할 수 있습니다. 요금 납부 적립률도 등급에 따라 달라집니다.", False),
        ]])


def seed_data():
    if Plan.query.first():
        return

    tiers = [MembershipTier(code=c, name=n, min_monthly_fee=f, rank=r, earn_rate_bp=EARN_RATE_BP[c]) for c, n, f, r in [
        ("BASIC", "일반유저", 0, 0), ("SILVER", "Plus", 35000, 1),
        ("GOLD", "VIP", 60000, 2), ("VIP", "Admin", 85000, 3)]]
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
    # 보안 대시보드: 차단하면 안 되는 loopback + 실습과 같은 자동 차단 1건 (문서용 주소 203.0.113.0/24)
    for cidr, memo in (("127.0.0.1/32", "loopback (서버 자신)"), ("::1/128", "loopback IPv6")):
        if not IpWhitelist.query.filter_by(cidr=cidr).first():  # Migration 이 이미 넣었으면 건너뜀
            db.session.add(IpWhitelist(cidr=cidr, memo=memo))
    now = utcnow()
    db.session.add(IpBlock(ip="203.0.113.44", reason="공격 출발지 자동 차단: 6회 로그인 실패(동일 IP)",
                           source="AUTOMATION", workflow="4-ip-block", created_at=now, expires_at=now + _td(minutes=60)))
    db.session.add(SecurityAuditLog(actor_type="AUTOMATION", workflow="4-ip-block", action="ip.block",
                                    target_type="ip", target="203.0.113.44", reason="합성 시드", created_at=now))
    _shop_and_notices()
    db.session.commit()
