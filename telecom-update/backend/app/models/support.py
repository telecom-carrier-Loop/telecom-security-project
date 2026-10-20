from sqlalchemy import ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db
from .base import TimestampMixin

TICKET_STATUSES = ("OPEN", "IN_PROGRESS", "ANSWERED", "CLOSED")


class SupportTicket(TimestampMixin, db.Model):
    __tablename__ = "support_tickets"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), nullable=False, index=True)
    category: Mapped[str] = mapped_column(String(30), nullable=False, default="GENERAL")
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)  # 원문 저장, 출력 시 이스케이프 (React 기본 동작)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="OPEN", index=True)


class SupportReply(TimestampMixin, db.Model):
    __tablename__ = "support_replies"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    ticket_id: Mapped[int] = mapped_column(ForeignKey("support_tickets.id", ondelete="CASCADE"), nullable=False, index=True)
    author_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="RESTRICT"), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)
