"""6단계: 고객 문의사항.

고객: 본인 문의만 조회·작성·수정·종료 (남의 문의는 존재 여부도 알려주지 않고 404)
관리자(ADMIN): 전체 조회·답변·상태 변경
문의 본문은 받은 그대로 저장하고, 화면(React)이 출력할 때 이스케이프한다 → 스크립트가 실행되지 않음.
"""
from flask import Blueprint, request

from ..core.errors import ApiError
from ..core.permissions import ROLE_ADMIN, current_user, login_required, object_denied, roles_required
from ..core.responses import ok
from ..core.validation import body, raise_if, text
from ..extensions import db
from ..models import SupportReply, SupportTicket, User
from ..models.support import TICKET_STATUSES

bp = Blueprint("support", __name__, url_prefix="/api")

CATEGORIES = {"GENERAL": "일반", "BILLING": "요금·결제", "PLAN": "요금제", "MEMBERSHIP": "멤버십", "NETWORK": "통화·데이터 품질"}


def ticket_dict(t: SupportTicket, *, with_replies=False, with_customer=False, with_content=False) -> dict:
    data = {"id": t.id, "category": t.category, "category_label": CATEGORIES.get(t.category, t.category),
            "title": t.title, "status": t.status,
            "created_at": t.created_at.isoformat() + "Z", "updated_at": t.updated_at.isoformat() + "Z"}
    if with_content or with_replies:
        data["content"] = t.content
        data["reply_count"] = SupportReply.query.filter_by(ticket_id=t.id).count()
    if with_replies:
        data["content"] = t.content
        replies = SupportReply.query.filter_by(ticket_id=t.id).order_by(SupportReply.created_at).all()
        data["replies"] = [{"id": r.id, "content": r.content, "author": "상담원",
                            "created_at": r.created_at.isoformat() + "Z"} for r in replies]
    if with_customer:
        customer = db.session.get(User, t.user_id)
        data["customer"] = {"id": customer.id, "name": customer.name, "email": mask_email(customer.email)}
        data["customer_name"] = customer.name
    return data


def mask_email(email: str) -> str:
    """관리 화면용 이메일 가리기: alice@test.local → al***@test.local (최소 노출)"""
    local, _, domain = email.partition("@")
    return f"{local[:2]}***@{domain}" if domain else "***"


def _validated_ticket(data: dict, partial=False) -> dict:
    errors = {}
    out = {}
    if not partial or "title" in data:
        out["title"] = text(data, "title", "제목", 2, 120, errors)
    if not partial or "content" in data:
        out["content"] = text(data, "content", "내용", 5, 3000, errors)
    if not partial:
        category = data.get("category") or "GENERAL"
        if category not in CATEGORIES:
            errors["category"] = "문의 유형을 선택하세요."
        out["category"] = category
    raise_if(errors)
    return out


def _my_ticket(ticket_id: int) -> SupportTicket:
    user = current_user()
    ticket = db.session.get(SupportTicket, ticket_id)
    if ticket is None:
        raise ApiError("NOT_FOUND", "문의를 찾을 수 없습니다.", 404)
    if ticket.user_id != user.id:  # 남의 문의 (IDOR) → 이벤트 + 존재 여부 숨긴 404
        raise object_denied("support_ticket", ticket_id, "문의를 찾을 수 없습니다.")
    return ticket


# ---------- 고객 ----------

@bp.get("/support/categories")
def categories():
    return ok({"categories": [{"code": k, "label": v} for k, v in CATEGORIES.items()]})


@bp.get("/support")
@login_required
def my_tickets():
    tickets = (SupportTicket.query.filter_by(user_id=current_user().id)
               .order_by(SupportTicket.created_at.desc()).all())
    return ok({"tickets": [ticket_dict(t) for t in tickets]})


@bp.post("/support")
@login_required
def create_ticket():
    clean = _validated_ticket(body())
    ticket = SupportTicket(user_id=current_user().id, **clean)
    db.session.add(ticket)
    db.session.commit()
    return ok({"ticket": ticket_dict(ticket, with_replies=True)}, 201)


@bp.get("/support/<int:ticket_id>")
@login_required
def get_ticket(ticket_id):
    return ok({"ticket": ticket_dict(_my_ticket(ticket_id), with_replies=True)})


@bp.patch("/support/<int:ticket_id>")
@login_required
def update_ticket(ticket_id):
    ticket = _my_ticket(ticket_id)
    if ticket.status != "OPEN":
        raise ApiError("CONFLICT", "상담이 시작된 문의는 수정할 수 없습니다.", 409)
    for key, value in _validated_ticket(body(), partial=True).items():
        setattr(ticket, key, value)
    db.session.commit()
    return ok({"ticket": ticket_dict(ticket, with_replies=True)})


@bp.post("/support/<int:ticket_id>/close")
@login_required
def close_ticket(ticket_id):
    ticket = _my_ticket(ticket_id)
    ticket.status = "CLOSED"
    db.session.commit()
    return ok({"ticket": ticket_dict(ticket, with_replies=True)})


# ---------- 관리자 ----------

@bp.get("/admin/support")
@roles_required(ROLE_ADMIN)
def admin_list():
    query = SupportTicket.query
    status = request.args.get("status")
    if status in TICKET_STATUSES:
        query = query.filter_by(status=status)
    tickets = query.order_by(SupportTicket.created_at.desc()).limit(200).all()
    # 목록에서 바로 내용을 읽고 답할 수 있도록 본문까지 내려준다 (관리자 전용)
    return ok({"tickets": [ticket_dict(t, with_customer=True, with_content=True) for t in tickets]})


@bp.get("/admin/support/<int:ticket_id>")
@roles_required(ROLE_ADMIN)
def admin_get(ticket_id):
    ticket = db.session.get(SupportTicket, ticket_id) or _not_found()
    return ok({"ticket": ticket_dict(ticket, with_replies=True, with_customer=True)})


@bp.post("/admin/support/<int:ticket_id>/replies")
@roles_required(ROLE_ADMIN)
def admin_reply(ticket_id):
    ticket = db.session.get(SupportTicket, ticket_id) or _not_found()
    if ticket.status == "CLOSED":
        raise ApiError("CONFLICT", "종료된 문의에는 답변할 수 없습니다.", 409)
    errors = {}
    content = text(body(), "content", "답변", 2, 3000, errors)
    raise_if(errors)
    db.session.add(SupportReply(ticket_id=ticket.id, author_id=current_user().id, content=content))
    ticket.status = "ANSWERED"
    db.session.commit()
    return ok({"ticket": ticket_dict(ticket, with_replies=True, with_customer=True)}, 201)


@bp.patch("/admin/support/<int:ticket_id>")
@roles_required(ROLE_ADMIN)
def admin_status(ticket_id):
    ticket = db.session.get(SupportTicket, ticket_id) or _not_found()
    status = body().get("status")
    if status not in TICKET_STATUSES:
        raise_if({"status": "상태 값이 올바르지 않습니다."})
    ticket.status = status
    db.session.commit()
    return ok({"ticket": ticket_dict(ticket, with_replies=True, with_customer=True)})


def _not_found():
    raise ApiError("NOT_FOUND", "문의를 찾을 수 없습니다.", 404)
