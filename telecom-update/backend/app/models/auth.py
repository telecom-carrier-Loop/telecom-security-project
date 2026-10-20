from datetime import datetime

from sqlalchemy import DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db


class AuthSession(db.Model):
    """MySQL 공유 서버 세션 (통합 기준 7절). 양 API Pod가 같은 테이블로 인증한다.

    브라우저에는 무작위 opaque token만 주고, DB에는 SHA-256 해시만 저장한다.
    """
    __tablename__ = "auth_sessions"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    token_hash: Mapped[str] = mapped_column(String(64), unique=True, nullable=False)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), nullable=False, index=True)
    # CSRF 토큰: 세션 쿠키 없이는 쓸모가 없고, 화면 새로고침 후 다시 내려주기 위해 저장한다
    csrf_token: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    last_seen_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)
    expires_at: Mapped[datetime] = mapped_column(DateTime, nullable=False, index=True)  # 절대 만료
    revoked_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)


class AuthLoginFailure(db.Model):
    """로그인 실패 기록. 공유 DB에 쌓아 두 Pod가 같은 제한을 적용한다.

    key_type: ACCOUNT(정규화 이메일의 해시) / IP. 존재하지 않는 계정도 같은 방식으로 센다.
    """
    __tablename__ = "auth_login_failures"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    key_type: Mapped[str] = mapped_column(String(10), nullable=False)
    key_hash: Mapped[str] = mapped_column(String(64), nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime, nullable=False)

    __table_args__ = (db.Index("ix_login_failures_key_time", "key_type", "key_hash", "created_at"),)
