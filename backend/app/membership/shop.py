"""L∞P+ 포인트 상점.

- 가격·재고·등급 조건은 서버가 판단 (요청 본문의 가격은 무시)
- 계정 행 잠금 + 재고 조건부 UPDATE → 동시에 눌러도 재고·포인트가 음수가 되지 않음
- 원장 business_ref = shop:<order_id> UNIQUE, (user_id, Idempotency-Key) UNIQUE 로 이중 차감 방지
"""
import secrets

from flask import Blueprint, request
from sqlalchemy import update
from sqlalchemy.exc import IntegrityError

from ..core.errors import ApiError, not_found, validation_error
from ..core.logging import app_log, security_event
from ..core.permissions import ROLE_ADMIN, current_user, login_required, roles_required
from ..core.responses import ok
from ..core.validation import body, idempotency_conflict, idempotency_key, request_hash
from ..extensions import db
from ..models import MembershipAccount, ShopItem, ShopOrder
from .service import add_points, locked_account

bp = Blueprint("shop", __name__, url_prefix="/api")
CATEGORIES = ("GOODS", "DATA", "COUPON")


def item_dict(i: ShopItem, rank=None) -> dict:
    return {"id": i.id, "name": i.name, "description": i.description, "category": i.category,
            "price_points": i.price_points, "stock": i.stock, "min_tier_rank": i.min_tier_rank,
            "is_active": i.is_active, "sold_out": i.stock == 0,
            "available": None if rank is None else (i.is_active and i.stock != 0 and rank >= i.min_tier_rank)}


def order_dict(o: ShopOrder) -> dict:
    return {"id": o.id, "item": o.item.name, "points": o.points, "status": o.status, "code": o.code,
            "created_at": o.created_at.isoformat() + "Z"}


@bp.get("/membership/shop")
@login_required
def shop_items():
    account = MembershipAccount.query.filter_by(user_id=current_user().id).first()
    rank = account.tier.rank if account else None
    rows = ShopItem.query.filter_by(is_active=True).order_by(ShopItem.min_tier_rank, ShopItem.price_points).all()
    return ok({"items": [item_dict(i, rank if rank is not None else -1) for i in rows],
               "balance": account.point_balance if account else None,
               "tier": {"name": account.tier.name, "rank": account.tier.rank} if account else None})


@bp.get("/membership/shop/orders")
@login_required
def my_orders():
    rows = ShopOrder.query.filter_by(user_id=current_user().id).order_by(ShopOrder.id.desc()).limit(50).all()
    return ok({"orders": [order_dict(o) for o in rows]})


@bp.post("/membership/shop/<int:item_id>/purchase")
@login_required
def purchase(item_id):
    user, key = current_user(), idempotency_key()
    req_hash = request_hash("shop.purchase", {"item_id": item_id})
    replay = ShopOrder.query.filter_by(user_id=user.id, idempotency_key=key).first()
    if replay:
        if replay.request_hash != req_hash:
            raise idempotency_conflict()
        return ok({"order": order_dict(replay), "replayed": True})

    account = locked_account(user.id)
    if account is None:
        raise ApiError("NOT_MEMBER", "L∞P+ 멤버십에 먼저 가입하세요.", 403)
    item = ShopItem.query.filter_by(id=item_id, is_active=True).first()
    if item is None:
        raise not_found("상품을 찾을 수 없습니다.")
    if account.tier.rank < item.min_tier_rank:
        security_event("membership.redeem.denied", "low", "등급 미달 상품 교환 시도", user_id=user.id,
                       shop_item_id=item.id, reason="tier")
        raise ApiError("TIER_REQUIRED", "현재 등급으로는 교환할 수 없는 상품입니다.", 403)
    if account.point_balance < item.price_points:
        raise ApiError("INSUFFICIENT_POINTS", "포인트가 부족합니다.", 409)
    if item.stock is not None:
        taken = db.session.execute(update(ShopItem).where(ShopItem.id == item.id, ShopItem.stock > 0)
                                   .values(stock=ShopItem.stock - 1)).rowcount
        if taken != 1:
            db.session.rollback()
            raise ApiError("SOLD_OUT", "품절된 상품입니다.", 409)

    order = ShopOrder(user_id=user.id, item_id=item.id, points=item.price_points, status="COMPLETED",
                      code=f"LOOP-{secrets.token_hex(5).upper()}", idempotency_key=key, request_hash=req_hash)
    db.session.add(order)
    try:
        db.session.flush()
        add_points(account, -item.price_points, "USE", f"포인트 상점: {item.name}", f"shop:{order.id}")
        db.session.commit()
    except IntegrityError:
        db.session.rollback()
        again = ShopOrder.query.filter_by(user_id=user.id, idempotency_key=key).first()
        if again and again.request_hash == req_hash:
            return ok({"order": order_dict(again), "replayed": True})
        raise ApiError("CONFLICT", "주문을 처리하지 못했습니다. 다시 시도하세요.", 409)
    app_log("shop.purchased", user_id=user.id, order_id=order.id, item_id=item.id, points=item.price_points)
    return ok({"order": order_dict(order), "replayed": False, "balance": account.point_balance}, 201)


# ---------- 관리자: 상품 관리 ----------

def _clean_item(data: dict, partial=False) -> dict:
    out, errors = {}, {}
    if not partial or "name" in data:
        name = str(data.get("name") or "").strip()
        if not 1 <= len(name) <= 60:
            errors["name"] = "상품명은 1~60자입니다."
        out["name"] = name
    if "description" in data:
        out["description"] = (str(data.get("description") or "").strip() or None) and str(data["description"]).strip()[:300]
    if not partial or "price_points" in data:
        p = data.get("price_points")
        if not isinstance(p, int) or isinstance(p, bool) or not 1 <= p <= 1_000_000:
            errors["price_points"] = "가격은 1~1,000,000 포인트입니다."
        out["price_points"] = p
    if "stock" in data:
        s = data.get("stock")
        if s is not None and (not isinstance(s, int) or isinstance(s, bool) or not 0 <= s <= 100_000):
            errors["stock"] = "재고는 0~100,000 또는 비움(무제한)입니다."
        out["stock"] = s
    if "min_tier_rank" in data:
        r = data.get("min_tier_rank")
        if not isinstance(r, int) or isinstance(r, bool) or not 0 <= r <= 3:
            errors["min_tier_rank"] = "등급은 0(Basic)~3(VIP)입니다."
        out["min_tier_rank"] = r
    if "category" in data:
        if data.get("category") not in CATEGORIES:
            errors["category"] = "분류가 올바르지 않습니다."
        out["category"] = data.get("category")
    if "is_active" in data:
        out["is_active"] = bool(data.get("is_active"))
    if errors:
        raise validation_error(errors)
    return out


@bp.get("/admin/membership/shop-items")
@roles_required(ROLE_ADMIN)
def admin_items():
    rows = ShopItem.query.order_by(ShopItem.id).all()
    sold = dict(db.session.query(ShopOrder.item_id, db.func.count(ShopOrder.id))
                .filter(ShopOrder.status == "COMPLETED").group_by(ShopOrder.item_id).all())
    return ok({"items": [{**item_dict(i), "sold": sold.get(i.id, 0)} for i in rows]})


@bp.post("/admin/membership/shop-items")
@roles_required(ROLE_ADMIN)
def admin_create_item():
    item = ShopItem(**_clean_item(body()))
    db.session.add(item)
    db.session.commit()
    app_log("shop.item.created", admin_id=current_user().id, item_id=item.id)
    return ok({"item": item_dict(item)}, 201)


@bp.patch("/admin/membership/shop-items/<int:item_id>")
@roles_required(ROLE_ADMIN)
def admin_update_item(item_id):
    item = db.session.get(ShopItem, item_id)
    if item is None:
        raise not_found("상품을 찾을 수 없습니다.")
    for k, v in _clean_item(body(), partial=True).items():
        setattr(item, k, v)
    db.session.commit()
    app_log("shop.item.updated", admin_id=current_user().id, item_id=item.id)
    return ok({"item": item_dict(item)})
