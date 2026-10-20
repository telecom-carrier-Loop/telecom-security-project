"""보안 대시보드용 테이블: 차단 IP · 화이트리스트 · 보안 작업 기록."""
from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db
from .base import utcnow

BLOCK_SOURCES = ("MANUAL", "AUTOMATION")
FIREWALL_STATUSES = ("SKIPPED", "PENDING", "SYNCED", "FAILED")


class IpBlock(db.Model):
    """앱(L7) 차단 목록. 차단된 IP의 /api 요청은 403.

    released_at 이 NULL 이고 (expires_at 이 NULL 이거나 미래) 이면 차단 중.
    firewall_status: 방화벽(pfSense) 연동 결과. 지금은 연동기가 없어서 SKIPPED (incidents/firewall.py 참고)
    """
    __tablename__ = "ip_blocks"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    ip: Mapped[str] = mapped_column(String(45), nullable=False, index=True)  # IPv4/IPv6 단일 주소
    reason: Mapped[str] = mapped_column(String(200), nullable=False)
    source: Mapped[str] = mapped_column(String(20), nullable=False)  # MANUAL / AUTOMATION
    workflow: Mapped[str | None] = mapped_column(String(64))  # 자동화일 때 n8n 워크플로 이름
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))  # 수동 차단한 관리자
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow)
    expires_at: Mapped[datetime | None] = mapped_column(DateTime, index=True)  # NULL = 영구 (관리자만 볼 수 있음)
    released_at: Mapped[datetime | None] = mapped_column(DateTime)
    released_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    hit_count: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
    last_hit_at: Mapped[datetime | None] = mapped_column(DateTime)
    firewall_status: Mapped[str] = mapped_column(String(10), nullable=False, default="SKIPPED", server_default="SKIPPED")
    firewall_ref: Mapped[str | None] = mapped_column(String(128))  # 방화벽 쪽 규칙 ID (연동 후 사용)


class IpWhitelist(db.Model):
    """차단하면 안 되는 주소 (관리 PC, 게이트웨이, loopback 등). 단일 IP 또는 CIDR."""
    __tablename__ = "ip_whitelist"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    cidr: Mapped[str] = mapped_column(String(49), unique=True, nullable=False)  # 예: 192.168.50.0/24, 127.0.0.1/32
    memo: Mapped[str | None] = mapped_column(String(100))
    created_by: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow)


class SecurityAuditLog(db.Model):
    """보안 작업 기록 (차단·해제·잠금·해제·회수·탈퇴 처리·자동 수신).

    화면에 '처리자' 열은 두지 않지만, 누가 했는지는 감사용으로 남긴다.
    자동화 현황 화면은 actor_type=AUTOMATION 행을 workflow 별로 묶어 보여준다.
    """
    __tablename__ = "security_audit_logs"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    actor_type: Mapped[str] = mapped_column(String(12), nullable=False)  # ADMIN / AUTOMATION / SYSTEM
    actor_id: Mapped[int | None] = mapped_column(ForeignKey("users.id"))
    workflow: Mapped[str | None] = mapped_column(String(64), index=True)
    action: Mapped[str] = mapped_column(String(40), nullable=False, index=True)
    target_type: Mapped[str] = mapped_column(String(20), nullable=False)  # ip / user / incident
    target: Mapped[str] = mapped_column(String(255), nullable=False)  # IP 또는 user id 등
    result: Mapped[str] = mapped_column(String(20), nullable=False, default="DONE")  # DONE / SKIPPED / ALREADY
    reason: Mapped[str | None] = mapped_column(String(200))
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, default=utcnow, index=True)
