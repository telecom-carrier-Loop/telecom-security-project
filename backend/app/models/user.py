from datetime import datetime

from argon2 import PasswordHasher
from argon2.exceptions import InvalidHashError, VerificationError
from sqlalchemy import Boolean, DateTime, Integer, String
from sqlalchemy.orm import Mapped, mapped_column

from ..extensions import db
from .base import TimestampMixin

# 통합 기준 7절: Argon2id, memory 64MiB · iterations 3 · parallelism 1 · salt 16바이트 · 출력 32바이트
PASSWORD_HASHER = PasswordHasher(time_cost=3, memory_cost=65536, parallelism=1, hash_len=32, salt_len=16)


class User(TimestampMixin, db.Model):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True)
    email: Mapped[str] = mapped_column(String(255), unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(String(255), nullable=False)
    name: Mapped[str] = mapped_column(String(50), nullable=False)
    # CUSTOMER / SUPPORT_ADMIN / SECURITY_ADMIN (공개 가입은 항상 CUSTOMER)
    role: Mapped[str] = mapped_column(String(20), nullable=False, default="CUSTOMER")
    is_active: Mapped[bool] = mapped_column(Boolean, nullable=False, default=True)
    # 계정 보안 정보 (홈·프로필에 표시)
    last_login_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    previous_login_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)
    failed_attempts_before_login: Mapped[int] = mapped_column(Integer, nullable=False, default=0, server_default="0")
    password_changed_at: Mapped[datetime | None] = mapped_column(DateTime, nullable=True)

    def set_password(self, raw: str) -> None:
        self.password_hash = PASSWORD_HASHER.hash(raw)

    def check_password(self, raw: str) -> bool:
        try:
            return PASSWORD_HASHER.verify(self.password_hash, raw)
        except (VerificationError, InvalidHashError):
            return False

    def to_public(self) -> dict:
        return {"id": self.id, "email": self.email, "name": self.name, "role": self.role}

    def to_profile(self) -> dict:
        from .membership import MembershipAccount

        iso = lambda d: d.isoformat() + "Z" if d else None  # noqa: E731
        return {
            **self.to_public(),
            # 고객에게 보이는 계정 유형 = L∞P+ 멤버십 가입 여부
            "membership_joined": MembershipAccount.query.filter_by(user_id=self.id).first() is not None,
            "created_at": iso(self.created_at),
            "previous_login_at": iso(self.previous_login_at),
            "failed_attempts_before_login": self.failed_attempts_before_login,
            "password_changed_at": iso(self.password_changed_at),
        }
