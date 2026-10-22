"""공지사항."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db
from .base import TimestampMixin

NOTICE_CATEGORIES = ("GENERAL", "MAINTENANCE", "EVENT", "SECURITY")


class Notice(TimestampMixin, db.Model):
    __tablename__ = "notices"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    category: Mapped[str] = mapped_column(String(20), nullable=False, default="GENERAL")
    title: Mapped[str] = mapped_column(String(120), nullable=False)
    content: Mapped[str] = mapped_column(Text, nullable=False)  # 평문 (HTML 해석 안 함 → XSS 방지)
    is_pinned: Mapped[bool] = mapped_column(nullable=False, default=False)
    is_published: Mapped[bool] = mapped_column(nullable=False, default=True)
    published_at: Mapped[datetime | None] = mapped_column(DateTime, index=True)
    author_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    view_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
