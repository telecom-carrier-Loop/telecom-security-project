-- 00_drop_all.sql — L∞P 테이블 전부 삭제 (되돌릴 수 없음)
-- 생성: L∞P 백엔드 Migration(head 6ddf5e18b8f4) 적용 결과에서 추출 · MySQL 8 / utf8mb4
-- 실행(PowerShell): Get-Content .\이파일.sql -Raw -Encoding UTF8 | docker exec -i mysql-server mysql -uroot -p<비밀번호> --default-character-set=utf8mb4 my_new_board_db
SET FOREIGN_KEY_CHECKS = 0;
DROP TABLE IF EXISTS `alembic_version`, `auth_login_failures`, `auth_sessions`, `benefit_redemptions`, `benefits`, `incident_histories`, `invoices`, `ip_blocks`, `ip_whitelist`, `membership_accounts`, `membership_tiers`, `notices`, `payment_events`, `payments`, `plans`, `point_transactions`, `security_audit_logs`, `security_incidents`, `shop_items`, `shop_orders`, `subscriptions`, `support_replies`, `support_tickets`, `usage_records`, `users`;
-- 다른 앱이 만든 테이블이 남아 있으면 함께 정리
DROP TABLE IF EXISTS `blocked_ips`, `incidents`, `posts`, `post`, `user`, `security_events`;
SET FOREIGN_KEY_CHECKS = 1;
