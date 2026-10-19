import json
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db
from .base import TimestampMixin

# 통합 기준 8절: OPEN → INVESTIGATING → RESOLVED → CLOSED, RESOLVED → INVESTIGATING 재개 허용
INCIDENT_STATUSES = ("OPEN", "INVESTIGATING", "RESOLVED", "CLOSED")
SEVERITIES = ("info", "low", "medium", "high", "critical")


class SecurityIncident(TimestampMixin, db.Model):
    __tablename__ = "security_incidents"
    # 원본 이벤트 중복 키: 같은 (source, event_id) 는 티켓 1개
    __table_args__ = (UniqueConstraint("source", "event_id", name="uq_incident_source_event"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    source: Mapped[str] = mapped_column(String(30), nullable=False)
    event_id: Mapped[str] = mapped_column(String(128), nullable=False)
    event_type: Mapped[str] = mapped_column(String(60), nullable=False)
    # 정규화 원본 필드의 SHA-256 (received_at·collector·재시도 횟수 제외) → 같은 키·다른 내용 판별
    event_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    severity: Mapped[str] = mapped_column(String(10), nullable=False, index=True)
    title: Mapped[str] = mapped_column(String(200), nullable=False)
    description: Mapped[str | None] = mapped_column(Text)
    asset_host: Mapped[str | None] = mapped_column(String(64))
    asset_service: Mapped[str | None] = mapped_column(String(64))
    scenario_id: Mapped[str | None] = mapped_column(String(64))
    origin_request_id: Mapped[str | None] = mapped_column(String(128))
    evidence_json: Mapped[str | None] = mapped_column(Text)
    status: Mapped[str] = mapped_column(String(20), nullable=False, default="OPEN", index=True)
    assigned_to: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    detected_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime)

    @property
    def evidence(self):
        return json.loads(self.evidence_json) if self.evidence_json else None


class IncidentHistory(TimestampMixin, db.Model):
    __tablename__ = "incident_histories"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    incident_id: Mapped[int] = mapped_column(ForeignKey("security_incidents.id", ondelete="CASCADE"), nullable=False, index=True)
    actor_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))  # 자동 수신이면 NULL
    action: Mapped[str] = mapped_column(String(30), nullable=False)  # CREATED/STATUS_CHANGED/ASSIGNED/NOTE
    note: Mapped[str | None] = mapped_column(Text)
