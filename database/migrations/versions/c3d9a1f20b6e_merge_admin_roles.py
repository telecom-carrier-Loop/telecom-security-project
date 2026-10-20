"""관리자 역할 통합: SUPPORT_ADMIN·SECURITY_ADMIN → ADMIN

역할 변경이므로 해당 사용자의 기존 세션도 폐기한다 (통합 기준 7절: 권한 변경 시 세션 폐기).

Revision ID: c3d9a1f20b6e
Revises: b72e4713f5b9
Create Date: 2026-10-19
"""
from alembic import op

revision = 'c3d9a1f20b6e'
down_revision = 'b72e4713f5b9'
branch_labels = None
depends_on = None


def upgrade():
    op.execute("UPDATE auth_sessions SET revoked_at = CURRENT_TIMESTAMP "
               "WHERE revoked_at IS NULL AND user_id IN "
               "(SELECT id FROM users WHERE role IN ('SUPPORT_ADMIN', 'SECURITY_ADMIN'))")
    op.execute("UPDATE users SET role = 'ADMIN' WHERE role IN ('SUPPORT_ADMIN', 'SECURITY_ADMIN')")


def downgrade():
    # 어느 관리자가 상담/보안이었는지 기록이 없어 되돌릴 수 없다. 필요하면 수동으로 지정.
    pass
