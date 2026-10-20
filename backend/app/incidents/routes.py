"""보안 인시던트 (docs/contracts/incident-api.md, 통합 기준 12절)

자동 수신: POST /api/internal/incident-events
  - Authorization: Bearer <INCIDENT_API_TOKEN> (또는 X-API-Key). 브라우저 세션·CSRF와 분리, 관리자 API 권한 없음
  - (source, event_id) UNIQUE + 정규화 본문 해시
    최초 201 / 같은 키·같은 원본 200 deduplicated=true / 같은 키·다른 원본 409 / 입력 오류 422
  - 공개·관리 Nginx 모두 /api/internal 을 외부에 노출하지 않는다 (C·B)
수동 업무: /api/admin/incidents/*, ADMIN 전용
상태: OPEN → INVESTIGATING → RESOLVED → CLOSED, RESOLVED → INVESTIGATING 재개
"""
import hashlib
import hmac
import json
import re
import uuid
from datetime import datetime, timezone

from flask import Blueprint, current_app, request
from sqlalchemy.exc import IntegrityError

from ..core.errors import ApiError, not_found, validation_error
from ..core.permissions import ROLE_ADMIN, current_user, roles_required
from ..core.responses import ok
from ..core.validation import body, raise_if, text
from ..extensions import db
from ..models import IncidentHistory, SecurityIncident, User
from ..models.base import utcnow
from ..models.incident import INCIDENT_STATUSES, SEVERITIES

bp = Blueprint("incidents", __name__, url_prefix="/api")

TRANSITIONS = {
    "OPEN": {"INVESTIGATING"},
    "INVESTIGATING": {"RESOLVED"},
    "RESOLVED": {"CLOSED", "INVESTIGATING"},
    "CLOSED": set(),
}
SOURCE_RE = re.compile(r"^[a-z0-9][a-z0-9._-]{0,29}$")
EVENT_TYPE_RE = re.compile(r"^[a-z0-9_]+(\.[a-z0-9_]+){1,5}$")
# 해시에서 제외하는 수집 메타데이터 (경로가 달라도 같은 원본이면 같은 해시)
EXCLUDED_FROM_HASH = {"received_at", "collector", "retry_count", "attempt", "attempts"}
MAX_EVIDENCE_BYTES = 8 * 1024


def _iso(d):
    return d.isoformat() + "Z" if d else None


def incident_dict(i: SecurityIncident, detail=False) -> dict:
    assignee = db.session.get(User, i.assigned_to) if i.assigned_to else None
    data = {"id": i.id, "source": i.source, "event_id": i.event_id, "event_type": i.event_type,
            "severity": i.severity, "title": i.title, "status": i.status,
            "asset": {"host": i.asset_host, "service": i.asset_service},
            "assigned_to": None if not assignee else {"id": assignee.id, "name": assignee.name},
            "detected_at": _iso(i.detected_at), "resolved_at": _iso(i.resolved_at), "created_at": _iso(i.created_at)}
    if detail:
        data.update({"description": i.description, "scenario_id": i.scenario_id,
                     "request_id": i.origin_request_id, "evidence": i.evidence})
        rows = IncidentHistory.query.filter_by(incident_id=i.id).order_by(IncidentHistory.id).all()
        data["histories"] = [{"id": h.id, "action": h.action, "note": h.note,
                              "actor": (db.session.get(User, h.actor_id).name if h.actor_id else "자동 수신"),
                              "at": _iso(h.created_at)} for h in rows]
    return data


def _parse_utc(value, errors):
    if not isinstance(value, str):
        errors["detected_at"] = "UTC ISO 8601 시간이 필요합니다."
        return None
    try:
        dt = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors["detected_at"] = "UTC ISO 8601 시간이 아닙니다."
        return None
    if dt.tzinfo is None:
        errors["detected_at"] = "시간대(Z 또는 +00:00)가 필요합니다."
        return None
    return dt.astimezone(timezone.utc).replace(tzinfo=None)


def _optional_str(data, key, max_len, errors):
    value = data.get(key)
    if value is None:
        return None
    if not isinstance(value, str) or not 1 <= len(value) <= max_len:
        errors[key] = f"{key}은(는) 1~{max_len}자 문자열이어야 합니다."
        return None
    return value


def validate_event(data: dict) -> dict:
    """event-schema.md 의 필수 필드를 검사하고 정규화한 값을 돌려준다."""
    errors: dict = {}
    if data.get("schema_version") != "1.0":
        errors["schema_version"] = "schema_version 은 \"1.0\" 이어야 합니다."
    source = data.get("source")
    if not isinstance(source, str) or not SOURCE_RE.match(source):
        errors["source"] = "source 는 소문자·숫자·._- 로 된 1~30자여야 합니다."
    event_id = text(data, "event_id", "event_id", 1, 128, errors)
    event_type = data.get("event_type")
    if not isinstance(event_type, str) or len(event_type) > 60 or not EVENT_TYPE_RE.match(event_type):
        errors["event_type"] = "event_type 은 auth.login.failed 같은 점 구분 이름이어야 합니다."
    detected_at = _parse_utc(data.get("detected_at"), errors)
    severity = data.get("severity")
    if severity not in SEVERITIES:
        errors["severity"] = f"severity 는 {'/'.join(SEVERITIES)} 중 하나여야 합니다."
    title = text(data, "title", "title", 1, 200, errors)
    asset = data.get("asset")
    if not isinstance(asset, dict):
        errors["asset"] = "asset 객체가 필요합니다."
        asset = {}
    for key in ("host", "service"):
        if asset.get(key) is not None and (not isinstance(asset[key], str) or len(asset[key]) > 64):
            errors[f"asset.{key}"] = "64자 이하 문자열이어야 합니다."
    scenario_id = _optional_str(data, "scenario_id", 64, errors)
    request_id = _optional_str(data, "request_id", 128, errors)
    description = _optional_str(data, "description", 5000, errors)
    evidence = data.get("evidence")
    if evidence is not None and (not isinstance(evidence, dict)
                                 or len(json.dumps(evidence, ensure_ascii=False)) > MAX_EVIDENCE_BYTES):
        errors["evidence"] = "evidence 는 8KB 이하 객체여야 합니다."
    if errors:
        raise validation_error(errors)

    normalized = {k: v for k, v in data.items() if k not in EXCLUDED_FROM_HASH}
    normalized["detected_at"] = detected_at.isoformat() + "Z"  # 표기 차이(+00:00/Z)를 같은 값으로
    event_hash = hashlib.sha256(json.dumps(normalized, sort_keys=True, ensure_ascii=False,
                                           separators=(",", ":")).encode()).hexdigest()
    return {"source": source, "event_id": event_id, "event_type": event_type, "detected_at": detected_at,
            "severity": severity, "title": title, "asset_host": asset.get("host"),
            "asset_service": asset.get("service"), "scenario_id": scenario_id, "origin_request_id": request_id,
            "description": description,
            "evidence_json": json.dumps(evidence, ensure_ascii=False) if evidence is not None else None,
            "event_hash": event_hash}


def create_or_get(fields: dict, actor_id=None, note=None):
    """반환: (incident, created). 같은 키·다른 해시는 409."""
    existing = SecurityIncident.query.filter_by(source=fields["source"], event_id=fields["event_id"]).first()
    if existing is None:
        incident = SecurityIncident(**fields)
        db.session.add(incident)
        try:
            db.session.flush()
            db.session.add(IncidentHistory(incident_id=incident.id, actor_id=actor_id, action="CREATED",
                                           note=note or f"{fields['source']} 이벤트로 생성"))
            db.session.commit()
            return incident, True
        except IntegrityError:  # 같은 이벤트가 두 경로로 동시에 도착 → UNIQUE 가 하나만 남긴다
            db.session.rollback()
            existing = SecurityIncident.query.filter_by(source=fields["source"], event_id=fields["event_id"]).one()
    if existing.event_hash != fields["event_hash"]:
        raise ApiError("EVENT_CONFLICT", "같은 (source, event_id)로 다른 내용의 이벤트가 이미 등록되었습니다.", 409)
    return existing, False


# ---------- 자동 수신 (n8n → loopback 내부 프록시 → API) ----------

@bp.post("/internal/incident-events")
def internal_incident_event():
    from .protection import audit, check_automation_token
    workflow = check_automation_token("INCIDENT_API_TOKEN")  # Bearer 또는 X-API-Key
    if not request.is_json:
        raise ApiError("UNSUPPORTED_MEDIA_TYPE", "JSON 요청만 허용합니다.", 415)
    incident, created = create_or_get(validate_event(body()))
    audit("incident.ingest", "incident", incident.id, actor_type="AUTOMATION", workflow=workflow,
          result="DONE" if created else "ALREADY")
    db.session.commit()
    return ok({"incident_id": incident.id, "deduplicated": not created, "status": incident.status},
              201 if created else 200)


# ---------- 관리자 ----------

@bp.get("/admin/incidents")
@roles_required(ROLE_ADMIN)
def admin_list():
    query = SecurityIncident.query
    status, severity = request.args.get("status"), request.args.get("severity")
    if status == "ACTIVE":
        query = query.filter(SecurityIncident.status.in_(("OPEN", "INVESTIGATING")))
    elif status in INCIDENT_STATUSES:
        query = query.filter_by(status=status)
    if severity in SEVERITIES:
        query = query.filter_by(severity=severity)
    rows = query.order_by(SecurityIncident.detected_at.desc()).limit(200).all()
    return ok({"incidents": [incident_dict(i) for i in rows]})


@bp.get("/admin/incidents/assignees")
@roles_required(ROLE_ADMIN)
def assignees():
    users = User.query.filter_by(role=ROLE_ADMIN, is_active=True).order_by(User.name).all()
    return ok({"assignees": [{"id": u.id, "name": u.name} for u in users]})


@bp.post("/admin/incidents")
@roles_required(ROLE_ADMIN)
def admin_create():
    data = body()
    event = {"schema_version": "1.0", "source": "manual", "event_id": f"manual-{uuid.uuid4().hex[:16]}",
             "event_type": data.get("event_type") or "manual.report",
             "detected_at": data.get("detected_at") or utcnow().isoformat() + "Z",
             "severity": data.get("severity"), "title": data.get("title"),
             "asset": data.get("asset") or {}, "description": data.get("description")}
    incident, _ = create_or_get(validate_event(event), actor_id=current_user().id, note="관리자가 직접 등록")
    return ok({"incident": incident_dict(incident, detail=True)}, 201)


def _get(incident_id):
    incident = db.session.get(SecurityIncident, incident_id)
    if incident is None:
        raise not_found("인시던트를 찾을 수 없습니다.")
    return incident


@bp.get("/admin/incidents/<int:incident_id>")
@roles_required(ROLE_ADMIN)
def admin_get(incident_id):
    return ok({"incident": incident_dict(_get(incident_id), detail=True)})


@bp.patch("/admin/incidents/<int:incident_id>")
@roles_required(ROLE_ADMIN)
def admin_update(incident_id):
    incident, data, actor = _get(incident_id), body(), current_user()
    changes = []

    if "status" in data and data["status"] != incident.status:
        new = data["status"]
        if new not in TRANSITIONS.get(incident.status, set()):
            raise ApiError("INVALID_TRANSITION", f"{incident.status} → {new} 로 바꿀 수 없습니다.", 409)
        changes.append(("STATUS_CHANGED", f"{incident.status} → {new}"))
        incident.status = new
        incident.resolved_at = utcnow() if new in ("RESOLVED", "CLOSED") else None

    if "assigned_to" in data:
        target = data["assigned_to"]
        user = None
        if target is not None:
            user = db.session.get(User, target) if isinstance(target, int) and not isinstance(target, bool) else None
            if user is None or user.role != ROLE_ADMIN or not user.is_active:
                raise validation_error({"assigned_to": "관리자만 담당자로 지정할 수 있습니다."})
        if target != incident.assigned_to:
            incident.assigned_to = target
            changes.append(("ASSIGNED", "담당자 해제" if user is None else f"담당자: {user.name}"))

    if not changes:
        raise validation_error({"_": "바뀐 내용이 없습니다."})
    for action, note in changes:
        db.session.add(IncidentHistory(incident_id=incident.id, actor_id=actor.id, action=action, note=note))
    db.session.commit()
    return ok({"incident": incident_dict(incident, detail=True)})


@bp.post("/admin/incidents/<int:incident_id>/histories")
@roles_required(ROLE_ADMIN)
def admin_note(incident_id):
    incident = _get(incident_id)
    errors: dict = {}
    note = text(body(), "note", "대응 기록", 2, 3000, errors)
    raise_if(errors)
    db.session.add(IncidentHistory(incident_id=incident.id, actor_id=current_user().id, action="NOTE", note=note))
    db.session.commit()
    return ok({"incident": incident_dict(incident, detail=True)}, 201)


CLOSED_STATUSES = ("RESOLVED", "CLOSED")


@bp.post("/admin/incidents/delete")
@roles_required(ROLE_ADMIN)
def admin_delete():
    """인시던트 삭제 (시험 데이터·오탐 정리용).

    {ids: [..], reason, include_open: false}
    - 기본은 해결(RESOLVED)·종료(CLOSED)된 인시던트만 지운다. 처리 중인 공격 기록이 실수로 사라지지 않게
    - 처리 안 된 것(OPEN·INVESTIGATING)까지 지우려면 include_open: true 를 명시해야 한다
    - 대응 이력도 함께 지운다. 차단·잠금 등 이미 실행된 조치는 남는다
    - 무엇을 지웠는지(출처·이벤트 ID·제목)는 지울 수 없는 관리자 작업 기록으로 남긴다
    - 같은 (source, event_id) 이벤트가 다시 오면 새 티켓이 생긴다
    """
    from .protection import audit, clean_reason

    data, admin = body(), current_user()
    ids = [i for i in (data.get("ids") or []) if isinstance(i, int) and not isinstance(i, bool)][:200]
    if not ids:
        raise validation_error({"ids": "삭제할 인시던트를 선택하세요."})
    include_open = data.get("include_open") is True
    reason = clean_reason(data.get("reason"), "인시던트 정리")

    rows = SecurityIncident.query.filter(SecurityIncident.id.in_(ids)).all()
    targets = [i for i in rows if include_open or i.status in CLOSED_STATUSES]
    skipped_open = len(rows) - len(targets)
    for inc in targets:
        audit("incident.delete", "incident", inc.id, actor_type="ADMIN", actor_id=admin.id,
              reason=f"{reason} | {inc.source}:{inc.event_id} | {inc.status} | {inc.title}")
        IncidentHistory.query.filter_by(incident_id=inc.id).delete(synchronize_session=False)
        db.session.delete(inc)
    db.session.commit()
    current_app.logger.info("incident.deleted", extra={"event": {"evidence": {
        "admin_id": admin.id, "deleted": len(targets), "skipped_open": skipped_open}}})
    return ok({"deleted": len(targets), "skipped_open": skipped_open,
               "not_found": len(set(ids)) - len(rows)})
