from datetime import date

from sqlalchemy import Boolean, Date, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..extensions import db
from .base import TimestampMixin


class Plan(TimestampMixin, db.Model):
    __tablename__ = "plans"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    code: Mapped[str] = mapped_column(String(30), unique=True, nullable=False)
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    monthly_fee: Mapped[int] = mapped_column(Integer, nullable=False)  # 원 단위 정수
    data_mb: Mapped[int] = mapped_column(Integer, nullable=False)  # 무제한은 -1
    voice_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=-1)
    network: Mapped[str] = mapped_column(String(5), nullable=False, default="5G")
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)

    def to_dict(self) -> dict:
        return {
            "id": self.id, "code": self.code, "name": self.name, "monthly_fee": self.monthly_fee,
            "data_mb": self.data_mb, "voice_minutes": self.voice_minutes, "network": self.network,
        }


class Subscription(TimestampMixin, db.Model):
    __tablename__ = "subscriptions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id", ondelete="RESTRICT"), nullable=False)
    phone_number: Mapped[str] = mapped_column(String(20), unique=True, nullable=False)  # 가상 번호만
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="ACTIVE")  # ACTIVE/SUSPENDED/CANCELED
    started_on: Mapped[date] = mapped_column(Date, nullable=False)

    plan = relationship("Plan")


class UsageRecord(TimestampMixin, db.Model):
    __tablename__ = "usage_records"
    __table_args__ = (UniqueConstraint("subscription_id", "period", name="uq_usage_sub_period"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    subscription_id: Mapped[int] = mapped_column(ForeignKey("subscriptions.id", ondelete="CASCADE"), nullable=False)
    period: Mapped[str] = mapped_column(String(7), nullable=False)  # "2026-10"
    data_used_mb: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    voice_used_minutes: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
