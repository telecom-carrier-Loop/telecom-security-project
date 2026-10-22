-- 01_schema.sql — L∞P 테이블 25개 생성 (빈 DB에 1회)
-- 생성: L∞P 백엔드 Migration(head 6ddf5e18b8f4) 적용 결과에서 추출 · MySQL 8 / utf8mb4
-- 실행(PowerShell): Get-Content .\이파일.sql -Raw -Encoding UTF8 | docker exec -i mysql-server mysql -uroot -p<비밀번호> --default-character-set=utf8mb4 my_new_board_db
SET NAMES utf8mb4;
SET FOREIGN_KEY_CHECKS = 0;

/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `alembic_version` (
  `version_num` varchar(32) NOT NULL,
  PRIMARY KEY (`version_num`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `auth_login_failures` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `key_type` varchar(10) NOT NULL,
  `key_hash` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `ix_login_failures_key_time` (`key_type`,`key_hash`,`created_at`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `auth_sessions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `token_hash` varchar(64) NOT NULL,
  `user_id` int(11) NOT NULL,
  `csrf_token` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL,
  `last_seen_at` datetime NOT NULL,
  `expires_at` datetime NOT NULL,
  `revoked_at` datetime DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `token_hash` (`token_hash`),
  KEY `ix_auth_sessions_expires_at` (`expires_at`),
  KEY `ix_auth_sessions_user_id` (`user_id`),
  CONSTRAINT `auth_sessions_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `benefit_redemptions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `benefit_id` int(11) NOT NULL,
  `points_spent` int(11) NOT NULL,
  `status` varchar(20) NOT NULL,
  `idempotency_key` varchar(64) NOT NULL,
  `request_hash` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_redemption_idem` (`user_id`,`idempotency_key`),
  KEY `benefit_id` (`benefit_id`),
  KEY `ix_benefit_redemptions_user_id` (`user_id`),
  CONSTRAINT `benefit_redemptions_ibfk_1` FOREIGN KEY (`benefit_id`) REFERENCES `benefits` (`id`),
  CONSTRAINT `benefit_redemptions_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `benefits` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(60) NOT NULL,
  `partner` varchar(40) NOT NULL,
  `required_points` int(11) NOT NULL,
  `min_tier_rank` int(11) NOT NULL,
  `monthly_limit` int(11) NOT NULL,
  `is_active` tinyint(1) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `incident_histories` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `incident_id` int(11) NOT NULL,
  `actor_id` int(11) DEFAULT NULL,
  `action` varchar(30) NOT NULL,
  `note` text DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `actor_id` (`actor_id`),
  KEY `ix_incident_histories_incident_id` (`incident_id`),
  CONSTRAINT `incident_histories_ibfk_1` FOREIGN KEY (`actor_id`) REFERENCES `users` (`id`),
  CONSTRAINT `incident_histories_ibfk_2` FOREIGN KEY (`incident_id`) REFERENCES `security_incidents` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `invoices` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `subscription_id` int(11) NOT NULL,
  `period` varchar(7) NOT NULL,
  `amount` int(11) NOT NULL,
  `due_date` date NOT NULL,
  `status` varchar(20) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_invoice_sub_period` (`subscription_id`,`period`),
  KEY `ix_invoices_status` (`status`),
  KEY `ix_invoices_user_id` (`user_id`),
  CONSTRAINT `invoices_ibfk_1` FOREIGN KEY (`subscription_id`) REFERENCES `subscriptions` (`id`),
  CONSTRAINT `invoices_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `ip_blocks` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `ip` varchar(45) NOT NULL,
  `reason` varchar(200) NOT NULL,
  `source` varchar(20) NOT NULL,
  `workflow` varchar(64) DEFAULT NULL,
  `created_by` int(11) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `expires_at` datetime DEFAULT NULL,
  `released_at` datetime DEFAULT NULL,
  `released_by` int(11) DEFAULT NULL,
  `hit_count` int(11) NOT NULL DEFAULT 0,
  `last_hit_at` datetime DEFAULT NULL,
  `firewall_status` varchar(10) NOT NULL DEFAULT 'SKIPPED',
  `firewall_ref` varchar(128) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `created_by` (`created_by`),
  KEY `released_by` (`released_by`),
  KEY `ix_ip_blocks_expires_at` (`expires_at`),
  KEY `ix_ip_blocks_ip` (`ip`),
  CONSTRAINT `ip_blocks_ibfk_1` FOREIGN KEY (`created_by`) REFERENCES `users` (`id`),
  CONSTRAINT `ip_blocks_ibfk_2` FOREIGN KEY (`released_by`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `ip_whitelist` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `cidr` varchar(49) NOT NULL,
  `memo` varchar(100) DEFAULT NULL,
  `created_by` int(11) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `cidr` (`cidr`),
  KEY `created_by` (`created_by`),
  CONSTRAINT `ip_whitelist_ibfk_1` FOREIGN KEY (`created_by`) REFERENCES `users` (`id`)
) ENGINE=InnoDB AUTO_INCREMENT=3 DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `membership_accounts` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `tier_id` int(11) NOT NULL,
  `point_balance` int(11) NOT NULL,
  `version` int(11) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `user_id` (`user_id`),
  KEY `tier_id` (`tier_id`),
  CONSTRAINT `membership_accounts_ibfk_1` FOREIGN KEY (`tier_id`) REFERENCES `membership_tiers` (`id`),
  CONSTRAINT `membership_accounts_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`),
  CONSTRAINT `ck_point_balance_non_negative` CHECK (`point_balance` >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `membership_tiers` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `code` varchar(20) NOT NULL,
  `name` varchar(30) NOT NULL,
  `min_monthly_fee` int(11) NOT NULL,
  `rank` int(11) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  `earn_rate_bp` int(11) NOT NULL DEFAULT 100,
  PRIMARY KEY (`id`),
  UNIQUE KEY `code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `notices` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `category` varchar(20) NOT NULL,
  `title` varchar(120) NOT NULL,
  `content` text NOT NULL,
  `is_pinned` tinyint(1) NOT NULL,
  `is_published` tinyint(1) NOT NULL,
  `published_at` datetime DEFAULT NULL,
  `author_id` int(11) DEFAULT NULL,
  `view_count` int(11) NOT NULL DEFAULT 0,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `author_id` (`author_id`),
  KEY `ix_notices_published_at` (`published_at`),
  CONSTRAINT `notices_ibfk_1` FOREIGN KEY (`author_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `payment_events` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `payment_id` int(11) NOT NULL,
  `event_type` varchar(30) NOT NULL,
  `from_status` varchar(20) DEFAULT NULL,
  `to_status` varchar(20) NOT NULL,
  `detail` varchar(255) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `ix_payment_events_payment_id` (`payment_id`),
  CONSTRAINT `payment_events_ibfk_1` FOREIGN KEY (`payment_id`) REFERENCES `payments` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `payments` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `invoice_id` int(11) NOT NULL,
  `transaction_ref` varchar(64) NOT NULL,
  `idempotency_key` varchar(64) NOT NULL,
  `request_hash` varchar(64) NOT NULL,
  `success_invoice_id` int(11) DEFAULT NULL,
  `amount` int(11) NOT NULL,
  `method` varchar(20) NOT NULL,
  `status` varchar(20) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  `pg_tid` varchar(64) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `transaction_ref` (`transaction_ref`),
  UNIQUE KEY `uq_payment_idem` (`user_id`,`idempotency_key`),
  UNIQUE KEY `success_invoice_id` (`success_invoice_id`),
  UNIQUE KEY `uq_payments_pg_tid` (`pg_tid`),
  KEY `ix_payments_invoice_id` (`invoice_id`),
  KEY `ix_payments_user_id` (`user_id`),
  CONSTRAINT `payments_ibfk_1` FOREIGN KEY (`invoice_id`) REFERENCES `invoices` (`id`),
  CONSTRAINT `payments_ibfk_2` FOREIGN KEY (`success_invoice_id`) REFERENCES `invoices` (`id`),
  CONSTRAINT `payments_ibfk_3` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `plans` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `code` varchar(30) NOT NULL,
  `name` varchar(50) NOT NULL,
  `monthly_fee` int(11) NOT NULL,
  `data_mb` int(11) NOT NULL,
  `voice_minutes` int(11) NOT NULL,
  `network` varchar(5) NOT NULL,
  `is_active` tinyint(1) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `code` (`code`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `point_transactions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `account_id` int(11) NOT NULL,
  `amount` int(11) NOT NULL,
  `balance_after` int(11) NOT NULL,
  `kind` varchar(20) NOT NULL,
  `business_ref` varchar(64) NOT NULL,
  `memo` varchar(100) DEFAULT NULL,
  `redemption_id` int(11) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `business_ref` (`business_ref`),
  KEY `redemption_id` (`redemption_id`),
  KEY `ix_point_transactions_account_id` (`account_id`),
  CONSTRAINT `point_transactions_ibfk_1` FOREIGN KEY (`account_id`) REFERENCES `membership_accounts` (`id`),
  CONSTRAINT `point_transactions_ibfk_2` FOREIGN KEY (`redemption_id`) REFERENCES `benefit_redemptions` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `security_audit_logs` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `actor_type` varchar(12) NOT NULL,
  `actor_id` int(11) DEFAULT NULL,
  `workflow` varchar(64) DEFAULT NULL,
  `action` varchar(40) NOT NULL,
  `target_type` varchar(20) NOT NULL,
  `target` varchar(255) NOT NULL,
  `result` varchar(20) NOT NULL,
  `reason` varchar(200) DEFAULT NULL,
  `created_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `actor_id` (`actor_id`),
  KEY `ix_security_audit_logs_action` (`action`),
  KEY `ix_security_audit_logs_created_at` (`created_at`),
  KEY `ix_security_audit_logs_workflow` (`workflow`),
  CONSTRAINT `security_audit_logs_ibfk_1` FOREIGN KEY (`actor_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `security_incidents` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `source` varchar(30) NOT NULL,
  `event_id` varchar(128) NOT NULL,
  `event_type` varchar(60) NOT NULL,
  `event_hash` varchar(64) NOT NULL,
  `severity` varchar(10) NOT NULL,
  `title` varchar(200) NOT NULL,
  `description` text DEFAULT NULL,
  `asset_host` varchar(64) DEFAULT NULL,
  `asset_service` varchar(64) DEFAULT NULL,
  `scenario_id` varchar(64) DEFAULT NULL,
  `origin_request_id` varchar(128) DEFAULT NULL,
  `evidence_json` text DEFAULT NULL,
  `status` varchar(20) NOT NULL,
  `assigned_to` int(11) DEFAULT NULL,
  `detected_at` datetime NOT NULL,
  `resolved_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_incident_source_event` (`source`,`event_id`),
  KEY `assigned_to` (`assigned_to`),
  KEY `ix_security_incidents_severity` (`severity`),
  KEY `ix_security_incidents_status` (`status`),
  CONSTRAINT `security_incidents_ibfk_1` FOREIGN KEY (`assigned_to`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `shop_items` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `name` varchar(60) NOT NULL,
  `description` varchar(300) DEFAULT NULL,
  `category` varchar(20) NOT NULL,
  `price_points` int(11) NOT NULL,
  `stock` int(11) DEFAULT NULL,
  `min_tier_rank` int(11) NOT NULL,
  `is_active` tinyint(1) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  CONSTRAINT `ck_shop_price_positive` CHECK (`price_points` > 0),
  CONSTRAINT `ck_shop_stock_non_negative` CHECK (`stock` is null or `stock` >= 0)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `shop_orders` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `item_id` int(11) NOT NULL,
  `points` int(11) NOT NULL,
  `status` varchar(20) NOT NULL,
  `code` varchar(32) NOT NULL,
  `idempotency_key` varchar(64) NOT NULL,
  `request_hash` varchar(64) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `code` (`code`),
  UNIQUE KEY `uq_shop_order_idem` (`user_id`,`idempotency_key`),
  KEY `item_id` (`item_id`),
  KEY `ix_shop_orders_user_id` (`user_id`),
  CONSTRAINT `shop_orders_ibfk_1` FOREIGN KEY (`item_id`) REFERENCES `shop_items` (`id`),
  CONSTRAINT `shop_orders_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `subscriptions` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `plan_id` int(11) NOT NULL,
  `phone_number` varchar(20) NOT NULL,
  `status` varchar(20) NOT NULL,
  `started_on` date NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `phone_number` (`phone_number`),
  KEY `plan_id` (`plan_id`),
  KEY `ix_subscriptions_user_id` (`user_id`),
  CONSTRAINT `subscriptions_ibfk_1` FOREIGN KEY (`plan_id`) REFERENCES `plans` (`id`),
  CONSTRAINT `subscriptions_ibfk_2` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `support_replies` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `ticket_id` int(11) NOT NULL,
  `author_id` int(11) NOT NULL,
  `content` text NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `author_id` (`author_id`),
  KEY `ix_support_replies_ticket_id` (`ticket_id`),
  CONSTRAINT `support_replies_ibfk_1` FOREIGN KEY (`author_id`) REFERENCES `users` (`id`),
  CONSTRAINT `support_replies_ibfk_2` FOREIGN KEY (`ticket_id`) REFERENCES `support_tickets` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `support_tickets` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `user_id` int(11) NOT NULL,
  `category` varchar(30) NOT NULL,
  `title` varchar(120) NOT NULL,
  `content` text NOT NULL,
  `status` varchar(20) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  KEY `ix_support_tickets_status` (`status`),
  KEY `ix_support_tickets_user_id` (`user_id`),
  CONSTRAINT `support_tickets_ibfk_1` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `usage_records` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `subscription_id` int(11) NOT NULL,
  `period` varchar(7) NOT NULL,
  `data_used_mb` int(11) NOT NULL,
  `voice_used_minutes` int(11) NOT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `uq_usage_sub_period` (`subscription_id`,`period`),
  CONSTRAINT `usage_records_ibfk_1` FOREIGN KEY (`subscription_id`) REFERENCES `subscriptions` (`id`) ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;
/*!40101 SET @saved_cs_client     = @@character_set_client */;
/*!40101 SET character_set_client = utf8mb4 */;
CREATE TABLE `users` (
  `id` int(11) NOT NULL AUTO_INCREMENT,
  `email` varchar(255) NOT NULL,
  `password_hash` varchar(255) NOT NULL,
  `name` varchar(50) NOT NULL,
  `role` varchar(20) NOT NULL,
  `is_active` tinyint(1) NOT NULL,
  `last_login_at` datetime DEFAULT NULL,
  `previous_login_at` datetime DEFAULT NULL,
  `failed_attempts_before_login` int(11) NOT NULL DEFAULT 0,
  `password_changed_at` datetime DEFAULT NULL,
  `created_at` datetime NOT NULL,
  `updated_at` datetime NOT NULL,
  `locked_at` datetime DEFAULT NULL,
  `lock_reason` varchar(200) DEFAULT NULL,
  PRIMARY KEY (`id`),
  UNIQUE KEY `ix_users_email` (`email`)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
/*!40101 SET character_set_client = @saved_cs_client */;

-- Migration 기록 + 기본 화이트리스트(loopback)
INSERT INTO `alembic_version` VALUES
('6ddf5e18b8f4');
INSERT INTO `ip_whitelist` VALUES
(1,'127.0.0.1/32','loopback (서버 자신)',NULL,'2026-10-22 11:15:37'),
(2,'::1/128','loopback IPv6',NULL,'2026-10-22 11:15:37');

SET FOREIGN_KEY_CHECKS = 1;
