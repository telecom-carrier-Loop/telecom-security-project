"""가상 데이터 10명 (실제 고객정보 없음). 빈 DB에 Migration을 적용한 뒤 한 번 실행한다.

실행: backend 폴더에서  python -m flask --app wsgi seed-demo
- 기준 데이터: 요금제 4 · 멤버십 등급 4 · 혜택 3 (없으면 생성)
- 관리자 1명: admin@test.local
- 가상 고객 10명: customer01@test.local ~ customer10@test.local
  회선·이번 달 사용량·청구서(지난달 납부/이번 달 미납)·결제, 7명은 L∞P+ 회원, 문의 4건, 1명 잠금
- 보안 시드: 인시던트 3건, 자동 차단 IP 1건, 감사 기록
비밀번호는 모두 TEST_PASSWORD. 이미 customer01 이 있으면 아무것도 하지 않는다.
"""
import hashlib
import json
from datetime import date, timedelta

from app.extensions import db
EARN_RATE_BP = {'BASIC': 50, 'SILVER': 100, 'GOLD': 200, 'VIP': 300}  # 등급별 납부 적립률 (100 = 1%)

from app.models import (Notice, ShopItem, Benefit, IncidentHistory, Invoice, IpBlock, IpWhitelist, MembershipAccount, MembershipTier,
                        Payment, Plan, PointTransaction, SecurityAuditLog, SecurityIncident, Subscription,
                        SupportTicket, UsageRecord, User)
from app.models.base import utcnow

TEST_PASSWORD = "Test1234!"

CUSTOMERS = [
    # 이름, 요금제 코드, 데이터 사용(GB), 멤버십 등급(None=미가입), 포인트, 이번 달 미납 여부
    ("김하늘", "5G_BASIC", 8, "SILVER", 12000, True),
    ("이바다", "5G_STANDARD", 31, "GOLD", 3000, True),
    ("박구름", "LTE_SLIM", 4, None, 0, True),
    ("최별", "5G_PREMIUM", 142, "VIP", 25000, False),
    ("정노을", "5G_BASIC", 19, "SILVER", 4500, True),
    ("강바람", "5G_STANDARD", 67, "GOLD", 8000, False),
    ("윤새벽", "LTE_SLIM", 1, None, 0, True),
    ("한여름", "5G_PREMIUM", 88, "VIP", 15000, True),
    ("오가을", "5G_BASIC", 12, "BASIC", 1000, False),
    ("임겨울", "5G_STANDARD", 45, None, 0, True),
]
TICKETS = [
    (0, "BILLING", "이번 달 요금이 평소보다 높아요", "부가서비스 내역을 확인하고 싶습니다.", "OPEN"),
    (2, "NETWORK", "지하철에서 데이터가 자주 끊겨요", "2호선 강남역 근처에서 자주 끊깁니다.", "IN_PROGRESS"),
    (4, "PLAN", "요금제 변경 시점 문의", "월 중간에 바꾸면 요금이 어떻게 계산되나요?", "ANSWERED"),
    (7, "MEMBERSHIP", "VIP 혜택이 안 보여요", "영화 관람권이 목록에 없습니다.", "OPEN"),
]


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


def _hash(obj) -> str:
    return hashlib.sha256(json.dumps(obj, sort_keys=True, default=str).encode()).hexdigest()


def _reference_data():
    if not Plan.query.first():
        db.session.add_all([Plan(code=c, name=n, monthly_fee=f, data_mb=d, network=net) for c, n, f, d, net in [
            ("LTE_SLIM", "LTE 슬림", 25000, 6 * 1024, "LTE"),
            ("5G_BASIC", "5G Basic", 35000, 20 * 1024, "5G"),
            ("5G_STANDARD", "5G Standard", 55000, 110 * 1024, "5G"),
            ("5G_PREMIUM", "5G Premium", 85000, -1, "5G")]])
    if not MembershipTier.query.first():
        db.session.add_all([MembershipTier(code=c, name=n, min_monthly_fee=f, rank=r, earn_rate_bp=EARN_RATE_BP[c]) for c, n, f, r in [
            ("BASIC", "Basic", 0, 0), ("SILVER", "Silver", 35000, 1),
            ("GOLD", "Gold", 60000, 2), ("VIP", "VIP", 85000, 3)]])
    if not Benefit.query.first():
        db.session.add_all([
            Benefit(name="편의점 2,000원 할인", partner="가상편의점", required_points=2000, min_tier_rank=0),
            Benefit(name="영화 관람권", partner="가상시네마", required_points=9000, min_tier_rank=1),
            Benefit(name="카페 아메리카노", partner="가상카페", required_points=4500, min_tier_rank=1)])
    for cidr, memo in (("127.0.0.1/32", "loopback (서버 자신)"), ("::1/128", "loopback IPv6")):
        if not IpWhitelist.query.filter_by(cidr=cidr).first():
            db.session.add(IpWhitelist(cidr=cidr, memo=memo))
    db.session.flush()


def _user(email, name, role="CUSTOMER"):
    u = User(email=email, name=name, role=role, password_changed_at=utcnow())
    u.set_password(TEST_PASSWORD)
    db.session.add(u)
    db.session.flush()
    return u


def seed_demo() -> bool:
    if User.query.filter_by(email="customer01@test.local").first():
        return False
    _reference_data()
    plans = {p.code: p for p in Plan.query.all()}
    tiers = {t.code: t for t in MembershipTier.query.all()}
    admin = User.query.filter_by(email="admin@test.local").first() or _user("admin@test.local", "관리자", "ADMIN")

    today = date.today()
    period = today.strftime("%Y-%m")
    prev = today.replace(day=1) - timedelta(days=1)
    users = []
    for i, (name, plan_code, used_gb, tier_code, points, unpaid) in enumerate(CUSTOMERS, start=1):
        u = _user(f"customer{i:02d}@test.local", name)
        users.append(u)
        plan = plans[plan_code]
        sub = Subscription(user_id=u.id, plan_id=plan.id, phone_number=f"010-0000-{2000 + i}",  # 기본 시드(1001~)와 겹치지 않게
                           started_on=today - timedelta(days=30 * (i + 2)))
        db.session.add(sub)
        db.session.flush()
        db.session.add(UsageRecord(subscription_id=sub.id, period=period, data_used_mb=used_gb * 1024,
                                   voice_used_minutes=60 + i * 17))
        if tier_code:
            acc = MembershipAccount(user_id=u.id, tier_id=tiers[tier_code].id, point_balance=points)
            db.session.add(acc)
            db.session.flush()
            db.session.add(PointTransaction(account_id=acc.id, amount=points, balance_after=points, kind="EARN",
                                            memo="가입 축하 포인트", business_ref=f"demo-welcome:{u.id}"))
        paid = Invoice(user_id=u.id, subscription_id=sub.id, period=prev.strftime("%Y-%m"), amount=plan.monthly_fee,
                       due_date=prev.replace(day=25), status="PAID")
        current = Invoice(user_id=u.id, subscription_id=sub.id, period=period, amount=plan.monthly_fee,
                          due_date=today.replace(day=25), status="UNPAID" if unpaid else "PAID")
        db.session.add_all([paid, current])
        db.session.flush()
        for inv in (paid, current):
            if inv.status == "PAID":
                db.session.add(Payment(user_id=u.id, invoice_id=inv.id, amount=inv.amount, status="SUCCEEDED",
                                       transaction_ref=f"MOCK-DEMO-{u.id}-{inv.period}", success_invoice_id=inv.id,
                                       method="MOCK_CARD_4242", idempotency_key=f"demo-{u.id}-{inv.period}",
                                       request_hash=_hash(inv.id)))

    for idx, cat, title, content, status in TICKETS:
        db.session.add(SupportTicket(user_id=users[idx].id, category=cat, title=title, content=content, status=status))

    # 보안 시드: 1명 잠금(8번 봇), 자동 차단 1건(4번 봇), 인시던트 3건
    now = utcnow()
    locked = users[6]
    locked.locked_at, locked.lock_reason = now, "브루트포스 자동 잠금 (5회 실패)"
    db.session.add(IpBlock(ip="203.0.113.44", reason="공격 출발지 자동 차단: 6회 로그인 실패(동일 IP)",
                           source="AUTOMATION", workflow="4-ip-block", created_at=now, expires_at=now + timedelta(hours=1)))
    db.session.add_all([
        SecurityAuditLog(actor_type="AUTOMATION", workflow="4-ip-block", action="ip.block", target_type="ip",
                         target="203.0.113.44", reason="가상 데이터", created_at=now),
        SecurityAuditLog(actor_type="AUTOMATION", workflow="8-login-bruteforce", action="account.lock",
                         target_type="user", target=str(locked.id), reason="가상 데이터", created_at=now)])
    for src, eid, etype, sev, title, status in [
        ("suricata", "demo-ids-0001", "ids.suricata.alert", "high", "외부에서 DB 포트 접근 시도 탐지", "OPEN"),
        ("flask-api", "demo-auth-0001", "auth.login.failed", "medium", "동일 계정 로그인 실패 반복", "INVESTIGATING"),
        ("zabbix", "demo-zbx-0001", "infra.backup.failed", "low", "야간 백업 작업 실패", "RESOLVED"),
    ]:
        inc = SecurityIncident(source=src, event_id=eid, event_type=etype, severity=sev, title=title, status=status,
                               detected_at=now, event_hash=_hash([src, eid]), asset_host="pc1",
                               asset_service="telecom-api", assigned_to=admin.id if status != "OPEN" else None,
                               resolved_at=now if status == "RESOLVED" else None)
        db.session.add(inc)
        db.session.flush()
        db.session.add(IncidentHistory(incident_id=inc.id, action="CREATED", note=f"{src} 이벤트로 생성 (가상)"))
    _shop_and_notices(admin.id)
    db.session.commit()
    return True
