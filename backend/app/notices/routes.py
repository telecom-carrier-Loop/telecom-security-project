"""공지사항.

고객(로그인 불필요): GET /api/notices?category=&page= · GET /api/notices/{id}
관리자(ADMIN):     GET/POST /api/admin/notices · PATCH/DELETE /api/admin/notices/{id}
본문은 평문으로 저장·표시한다 (HTML 해석 안 함 → 저장형 XSS 방지).
"""
from flask import Blueprint, request

from ..core.errors import not_found, validation_error
from ..core.logging import app_log
from ..core.permissions import ROLE_ADMIN, current_user, roles_required
from ..core.responses import ok
from ..core.validation import body
from ..extensions import db
from ..models import Notice
from ..models.base import utcnow
from ..models.notice import NOTICE_CATEGORIES

bp = Blueprint("notices", __name__, url_prefix="/api")
CATEGORY_LABEL = {"GENERAL": "일반", "MAINTENANCE": "점검", "EVENT": "이벤트", "SECURITY": "보안"}


def _iso(d):
    return d.isoformat() + "Z" if d else None


def notice_dict(n: Notice, full=False) -> dict:
    data = {"id": n.id, "category": n.category, "category_label": CATEGORY_LABEL.get(n.category, n.category),
            "title": n.title, "is_pinned": n.is_pinned, "is_published": n.is_published,
            "published_at": _iso(n.published_at), "updated_at": _iso(n.updated_at), "view_count": n.view_count}
    if full:
        data["content"] = n.content
    else:
        data["summary"] = n.content[:90]
    return data


def _page():
    try:
        return max(int(request.args.get("page", 1)), 1)
    except ValueError:
        return 1


def _published():
    return Notice.query.filter(Notice.is_published.is_(True), Notice.published_at <= utcnow())


@bp.get("/notices")
def list_notices():
    page, size = _page(), 10
    query = _published()
    category = request.args.get("category")
    if category in NOTICE_CATEGORIES:
        query = query.filter(Notice.category == category)
    total = query.count()
    rows = (query.order_by(Notice.is_pinned.desc(), Notice.published_at.desc())
            .offset((page - 1) * size).limit(size).all())
    return ok({"notices": [notice_dict(n) for n in rows], "page": page, "size": size, "total": total,
               "categories": [{"code": c, "label": CATEGORY_LABEL[c]} for c in NOTICE_CATEGORIES]})


@bp.get("/notices/<int:notice_id>")
def get_notice(notice_id):
    n = _published().filter(Notice.id == notice_id).first()
    if n is None:
        raise not_found("공지사항을 찾을 수 없습니다.")
    n.view_count += 1
    db.session.commit()
    return ok({"notice": notice_dict(n, full=True)})


# ---------- 관리자 ----------

def _clean(data: dict, partial=False) -> dict:
    out, errors = {}, {}
    if not partial or "title" in data:
        t = str(data.get("title") or "").strip()
        if not 1 <= len(t) <= 120:
            errors["title"] = "제목은 1~120자입니다."
        out["title"] = t
    if not partial or "content" in data:
        c = str(data.get("content") or "").strip()
        if not 1 <= len(c) <= 10000:
            errors["content"] = "내용은 1~10,000자입니다."
        out["content"] = c
    if "category" in data or not partial:
        cat = data.get("category", "GENERAL")
        if cat not in NOTICE_CATEGORIES:
            errors["category"] = "분류가 올바르지 않습니다."
        out["category"] = cat
    for flag in ("is_pinned", "is_published"):
        if flag in data:
            out[flag] = bool(data.get(flag))
    if errors:
        raise validation_error(errors)
    return out


@bp.get("/admin/notices")
@roles_required(ROLE_ADMIN)
def admin_list():
    rows = Notice.query.order_by(Notice.is_pinned.desc(), Notice.id.desc()).limit(200).all()
    return ok({"notices": [notice_dict(n) for n in rows]})


@bp.get("/admin/notices/<int:notice_id>")
@roles_required(ROLE_ADMIN)
def admin_get(notice_id):
    n = db.session.get(Notice, notice_id)
    if n is None:
        raise not_found("공지사항을 찾을 수 없습니다.")
    return ok({"notice": notice_dict(n, full=True)})


@bp.post("/admin/notices")
@roles_required(ROLE_ADMIN)
def admin_create():
    data = _clean(body())
    n = Notice(**data, author_id=current_user().id)
    n.is_published = data.get("is_published", True)
    n.published_at = utcnow() if n.is_published else None
    db.session.add(n)
    db.session.commit()
    app_log("notice.created", admin_id=current_user().id, notice_id=n.id)
    return ok({"notice": notice_dict(n, full=True)}, 201)


@bp.patch("/admin/notices/<int:notice_id>")
@roles_required(ROLE_ADMIN)
def admin_update(notice_id):
    n = db.session.get(Notice, notice_id)
    if n is None:
        raise not_found("공지사항을 찾을 수 없습니다.")
    data = _clean(body(), partial=True)
    for k, v in data.items():
        setattr(n, k, v)
    if n.is_published and n.published_at is None:
        n.published_at = utcnow()
    db.session.commit()
    app_log("notice.updated", admin_id=current_user().id, notice_id=n.id)
    return ok({"notice": notice_dict(n, full=True)})


@bp.delete("/admin/notices/<int:notice_id>")
@roles_required(ROLE_ADMIN)
def admin_delete(notice_id):
    n = db.session.get(Notice, notice_id)
    if n is None:
        raise not_found("공지사항을 찾을 수 없습니다.")
    db.session.delete(n)
    db.session.commit()
    app_log("notice.deleted", admin_id=current_user().id, notice_id=notice_id)
    return ok({"deleted": True})
