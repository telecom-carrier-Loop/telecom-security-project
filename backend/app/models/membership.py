from sqlalchemy import CheckConstraint, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..extensions import db
from .base import TimestampMixin


class MembershipTier(TimestampMixin, db.Model):
    __tablename__ = "membership_tiers"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    code: Mapped[str] = mapped_column(String(20), unique=True, nullable=False)  # BASIC/SILVER/GOLD/VIP
    name: Mapped[str] = mapped_column(String(30), nullable=False)
    min_monthly_fee: Mapped[int] = mapped_column(Integer, nullable=False, default=0)  # 등급 조건 예시
    rank: Mapped[int] = mapped_column(Integer, nullable=False)


class MembershipAccount(TimestampMixin, db.Model):
    __tablename__ = "membership_accounts"
    __table_args__ = (CheckConstraint("point_balance >= 0", name="ck_point_balance_non_negative"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), unique=True, nullable=False)
    tier_id: Mapped[int] = mapped_column(ForeignKey("membership_tiers.id"), nullable=False)
    point_balance: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    # 동시 차감 방지용 낙관적 잠금 (7단계에서 사용)
    version: Mapped[int] = mapped_column(Integer, nullable=False, default=1)

    tier = relationship("MembershipTier")
    __mapper_args__ = {"version_id_col": version}


class PointTransaction(TimestampMixin, db.Model):
    """잔액만 바꾸지 않고 모든 적립·차감을 기록한다."""
    __tablename__ = "point_transactions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    account_id: Mapped[int] = mapped_column(ForeignKey("membership_accounts.id"), nullable=False, index=True)
    amount: Mapped[int] = mapped_column(Integer, nullable=False)  # +적립 / -사용
    balance_after: Mapped[int] = mapped_column(Integer, nullable=False)
    kind: Mapped[str] = mapped_column(String(20), nullable=False)  # EARN/REDEEM/REVERSE
    # 업무 식별자 (예: payment:12, redemption:5, welcome:3) — 같은 업무로 포인트가 두 번 반영되지 않게 UNIQUE
    business_ref: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    memo: Mapped[str | None] = mapped_column(String(100))
    redemption_id: Mapped[int | None] = mapped_column(ForeignKey("benefit_redemptions.id"))


class Benefit(TimestampMixin, db.Model):
    __tablename__ = "benefits"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(60), nullable=False)
    partner: Mapped[str] = mapped_column(String(40), nullable=False)
    required_points: Mapped[int] = mapped_column(Integer, nullable=False)
    min_tier_rank: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    monthly_limit: Mapped[int] = mapped_column(Integer, nullable=False, default=1)
    is_active: Mapped[bool] = mapped_column(nullable=False, default=True)

    def to_dict(self) -> dict:
        return {"id": self.id, "name": self.name, "partner": self.partner, "required_points": self.required_points,
                "min_tier_rank": self.min_tier_rank, "monthly_limit": self.monthly_limit, "is_active": self.is_active}


class BenefitRedemption(TimestampMixin, db.Model):
    __tablename__ = "benefit_redemptions"
    # 같은 요청 키로 두 번 사용 처리되지 않도록
    __table_args__ = (UniqueConstraint("user_id", "idempotency_key", name="uq_redemption_idem"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    benefit_id: Mapped[int] = mapped_column(ForeignKey("benefits.id"), nullable=False)
    points_spent: Mapped[int] = mapped_column(Integer, nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="USED")  # USED/CANCELED
    idempotency_key: Mapped[str] = mapped_column(String(64), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)  # 같은 키에 다른 내용 → 409
