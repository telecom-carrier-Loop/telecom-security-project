-- 04_host_additive_update.sql — 호스트 DB(my_new_board_db)에 "추가만" 하는 업데이트
--
-- 하는 일 (기존 데이터는 지우거나 바꾸지 않음)
--   1) 새 테이블 3개: notices, shop_items, shop_orders  (이미 있으면 건너뜀)
--   2) 기존 테이블에 컬럼 2개 추가: membership_tiers.earn_rate_bp, payments.pg_tid (+ 고유 인덱스)  (이미 있으면 건너뜀)
--      기존 행은 그대로이고 칸만 생김
--   3) 등급 4개의 적립률 값만 채움: BASIC 0.5% · SILVER 1% · GOLD 2% · VIP 3%  (예외적으로 UPDATE 하는 유일한 부분)
--   4) 더미데이터: 상점 상품 12종, 공지 3개  (같은 이름이 있으면 건너뜀)
--   5) Migration 기록: 35853b957d28 → 6ddf5e18b8f4  (나중에 flask db upgrade 가 이미 최신으로 인식하게)
-- 사용자·청구·결제·멤버십 계정 등 기존 데이터에는 INSERT/UPDATE/DELETE 없음. 여러 번 실행해도 안전.
-- 전제: DB가 35853b957d28(보안 대시보드) 단계여야 함 — 맨 위 SELECT 결과로 확인
SET NAMES utf8mb4;

SELECT version_num AS `현재 Migration (35853b957d28 이어야 함)` FROM alembic_version;

-- 1) 새 테이블
CREATE TABLE IF NOT EXISTS `notices` (
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

CREATE TABLE IF NOT EXISTS `shop_items` (
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

CREATE TABLE IF NOT EXISTS `shop_orders` (
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

-- 2) 기존 테이블에 컬럼 추가
SET @need := (SELECT COUNT(*) = 0 FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'membership_tiers' AND column_name = 'earn_rate_bp');
SET @sql := IF(@need, 'ALTER TABLE `membership_tiers` ADD COLUMN `earn_rate_bp` INT NOT NULL DEFAULT 100', 'SELECT ''membership_tiers.earn_rate_bp 이미 있음'' AS skip');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
SET @need := (SELECT COUNT(*) = 0 FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = 'payments' AND column_name = 'pg_tid');
SET @sql := IF(@need, 'ALTER TABLE `payments` ADD COLUMN `pg_tid` VARCHAR(64) NULL', 'SELECT ''payments.pg_tid 이미 있음'' AS skip');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;
SET @need := (SELECT COUNT(*) = 0 FROM information_schema.statistics WHERE table_schema = DATABASE() AND table_name = 'payments' AND index_name = 'uq_payments_pg_tid');
SET @sql := IF(@need, 'ALTER TABLE `payments` ADD CONSTRAINT `uq_payments_pg_tid` UNIQUE (`pg_tid`)', 'SELECT ''uq_payments_pg_tid 이미 있음'' AS skip');
PREPARE st FROM @sql; EXECUTE st; DEALLOCATE PREPARE st;

-- 3) 등급별 적립률 값
UPDATE membership_tiers SET earn_rate_bp = 50  WHERE code = 'BASIC';
UPDATE membership_tiers SET earn_rate_bp = 100 WHERE code = 'SILVER';
UPDATE membership_tiers SET earn_rate_bp = 200 WHERE code = 'GOLD';
UPDATE membership_tiers SET earn_rate_bp = 300 WHERE code = 'VIP';

-- 4) 더미데이터
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '데이터 500MB 쿠폰', '이번 달 데이터 500MB 추가 (가상)', 'DATA', 1500, NULL, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '데이터 500MB 쿠폰');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '음성통화 30분 추가', '이번 달 음성통화 30분 추가 (가상)', 'DATA', 2000, NULL, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '음성통화 30분 추가');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '데이터 1GB 쿠폰', '이번 달 데이터 1GB 추가 (가상)', 'DATA', 3000, NULL, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '데이터 1GB 쿠폰');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '편의점 3,000원 상품권', '가상편의점 모바일 상품권', 'COUPON', 3000, 100, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '편의점 3,000원 상품권');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '카페 아메리카노 교환권', '가상카페 아메리카노 1잔 모바일 교환권', 'COUPON', 4500, 200, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '카페 아메리카노 교환권');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT 'L∞P 에코백', 'L∞P 로고 캔버스 에코백 (가상 배송)', 'GOODS', 6000, 30, 1, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = 'L∞P 에코백');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT 'L∞P 텀블러', 'L∞P 로고 텀블러 (가상 배송)', 'GOODS', 8000, 20, 1, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = 'L∞P 텀블러');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '영화 관람권 1매', '가상시네마 2D 일반 관람권', 'COUPON', 9000, 50, 1, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '영화 관람권 1매');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '데이터 5GB 쿠폰', '이번 달 데이터 5GB 추가 (가상)', 'DATA', 12000, NULL, 2, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '데이터 5GB 쿠폰');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '보조배터리 10000mAh', 'L∞P 로고 보조배터리 (가상 배송)', 'GOODS', 25000, 10, 2, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '보조배터리 10000mAh');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '데이터 무제한 1일 이용권', '24시간 데이터 무제한 (가상, VIP 전용)', 'DATA', 20000, NULL, 3, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '데이터 무제한 1일 이용권');
INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '무선 이어폰', 'VIP 전용 한정 상품 (가상)', 'GOODS', 50000, 3, 3, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '무선 이어폰');

INSERT INTO notices (category, title, content, is_pinned, is_published, published_at, view_count, created_at, updated_at)
SELECT 'SECURITY', '[보안] L∞P를 사칭한 문자에 주의하세요', 'L∞P는 문자로 비밀번호나 카드 번호를 묻지 않습니다.\n의심 문자를 받으면 링크를 누르지 말고 1:1 문의로 알려 주세요.', 1, 1, UTC_TIMESTAMP(), 0, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM notices WHERE title = '[보안] L∞P를 사칭한 문자에 주의하세요');
INSERT INTO notices (category, title, content, is_pinned, is_published, published_at, view_count, created_at, updated_at)
SELECT 'MAINTENANCE', '10월 정기 점검 안내 (새벽 2시~4시)', '점검 시간 동안 요금 납부와 멤버십 기능을 잠시 사용할 수 없습니다.', 0, 1, UTC_TIMESTAMP(), 0, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM notices WHERE title = '10월 정기 점검 안내 (새벽 2시~4시)');
INSERT INTO notices (category, title, content, is_pinned, is_published, published_at, view_count, created_at, updated_at)
SELECT 'EVENT', 'L∞P+ 포인트 상점 오픈', '등급별로 다른 상품을 포인트로 교환할 수 있습니다. 요금 납부 적립률도 등급에 따라 달라집니다.', 0, 1, UTC_TIMESTAMP(), 0, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL WHERE NOT EXISTS (SELECT 1 FROM notices WHERE title = 'L∞P+ 포인트 상점 오픈');

-- 5) Migration 기록 (35853b957d28 일 때만)
UPDATE alembic_version SET version_num = '6ddf5e18b8f4' WHERE version_num = '35853b957d28';

-- 결과 확인
SELECT version_num AS `적용 후 Migration` FROM alembic_version;
SELECT code, earn_rate_bp FROM membership_tiers ORDER BY `rank`;
SELECT (SELECT COUNT(*) FROM shop_items) AS shop_items, (SELECT COUNT(*) FROM notices) AS notices, (SELECT COUNT(*) FROM shop_orders) AS shop_orders;
