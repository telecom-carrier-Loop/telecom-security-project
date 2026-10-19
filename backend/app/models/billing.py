from datetime import date

from sqlalchemy import Date, ForeignKey, Integer, String, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db
from .base import TimestampMixin

INVOICE_STATUSES = ("UNPAID", "PAID", "OVERDUE", "CANCELED")
PAYMENT_STATUSES = ("PENDING", "SUCCEEDED", "FAILED", "CANCELED", "REFUNDED")


class Invoice(TimestampMixin, db.Model):
    __tablename__ = "invoices"
    __table_args__ = (UniqueConstraint("subscription_id", "period", name="uq_invoice_sub_period"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    subscription_id: Mapped[int] = mapped_column(ForeignKey("subscriptions.id"), nullable=False)
    period: Mapped[str] = mapped_column(String(7), nullable=False)
    amount: Mapped[int] = mapped_column(Integer, nullable=False)  # 원 단위 정수, 결제 금액의 유일한 기준
    due_date: Mapped[date] = mapped_column(Date, nullable=False)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="UNPAID", index=True)

    def to_dict(self) -> dict:
        return {"id": self.id, "period": self.period, "amount": self.amount,
                "due_date": self.due_date.isoformat(), "status": self.status}


class Payment(TimestampMixin, db.Model):
    __tablename__ = "payments"
    __table_args__ = (UniqueConstraint("user_id", "idempotency_key", name="uq_payment_idem"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    invoice_id: Mapped[int] = mapped_column(ForeignKey("invoices.id"), nullable=False, index=True)
    transaction_ref: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)  # 모의 거래 식별자
    idempotency_key: Mapped[str] = mapped_column(String(64), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)  # 같은 키에 다른 내용 → 409
    # 성공한 결제에만 청구서 ID를 넣는다 → UNIQUE 라서 한 청구서에 성공 결제는 하나뿐 (NULL은 여러 개 허용)
    success_invoice_id: Mapped[int | None] = mapped_column(ForeignKey("invoices.id"), unique=True, nullable=True)
    amount: Mapped[int] = mapped_column(Integer, nullable=False)
    method: Mapped[str] = mapped_column(String(20), nullable=False, default="MOCK_CARD")
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="PENDING")

    def to_dict(self) -> dict:
        return {"id": self.id, "invoice_id": self.invoice_id, "amount": self.amount,
                "status": self.status, "method": self.method,
                "created_at": self.created_at.isoformat() + "Z"}


class PaymentEvent(TimestampMixin, db.Model):
    __tablename__ = "payment_events"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    payment_id: Mapped[int] = mapped_column(ForeignKey("payments.id", ondelete="CASCADE"), nullable=False, index=True)
    event_type: Mapped[str] = mapped_column(String(30), nullable=False)  # REQUESTED/APPROVED/FAILED/REFUNDED
    from_status: Mapped[str | None] = mapped_column(String(20))
    to_status: Mapped[str] = mapped_column(String(20), nullable=False)
    detail: Mapped[str | None] = mapped_column(String(255))
