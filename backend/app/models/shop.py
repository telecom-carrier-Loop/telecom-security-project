"""L∞P+ 포인트 상점: 상품과 교환 주문."""
from datetime import datetime

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column, relationship

from ..extensions import db
from .base import TimestampMixin


class ShopItem(TimestampMixin, db.Model):
    __tablename__ = "shop_items"
    __table_args__ = (CheckConstraint("price_points > 0", name="ck_shop_price_positive"),
                      CheckConstraint("stock IS NULL OR stock >= 0", name="ck_shop_stock_non_negative"))

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    name: Mapped[str] = mapped_column(String(60), nullable=False)
    description: Mapped[str | None] = mapped_column(String(300))
    category: Mapped[str] = mapped_column(String(20), nullable=False, default="GOODS")  # GOODS / DATA / COUPON
    price_points: Mapped[int] = mapped_column(Integer, nullable=False)
    stock: Mapped[int | None] = mapped_column(Integer, nullable=True)  # NULL = 무제한
    min_tier_rank: Mapped[int] = mapped_column(Integer, nullable=False, default=0)
    is_active: Mapped[bool] = mapped_column(nullable=False, default=True)


class ShopOrder(TimestampMixin, db.Model):
    __tablename__ = "shop_orders"
    __table_args__ = (UniqueConstraint("user_id", "idempotency_key", name="uq_shop_order_idem"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id"), nullable=False, index=True)
    item_id: Mapped[int] = mapped_column(ForeignKey("shop_items.id"), nullable=False)
    points: Mapped[int] = mapped_column(Integer, nullable=False)  # 주문 시점 가격 (나중에 가격이 바뀌어도 기록 유지)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="COMPLETED")  # COMPLETED / CANCELED
    code: Mapped[str] = mapped_column(String(32), unique=True, nullable=False)  # 가상 교환 코드
    idempotency_key: Mapped[str] = mapped_column(String(64), nullable=False)
    request_hash: Mapped[str] = mapped_column(String(64), nullable=False)

    item = relationship("ShopItem")
