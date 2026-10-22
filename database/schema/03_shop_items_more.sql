-- 03_shop_items_more.sql — 포인트 상점 상품 7종 추가 (이미 있는 이름은 건너뜀, 여러 번 실행해도 안전)
-- 실행(PowerShell): Get-Content .\03_shop_items_more.sql -Raw -Encoding UTF8 | docker exec -i mysql-server mysql -uroot -p<비밀번호> --default-character-set=utf8mb4 my_new_board_db
SET NAMES utf8mb4;

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '데이터 500MB 쿠폰', '이번 달 데이터 500MB 추가 (가상)', 'DATA', 1500, NULL, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '데이터 500MB 쿠폰');

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '음성통화 30분 추가', '이번 달 음성통화 30분 추가 (가상)', 'DATA', 2000, NULL, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '음성통화 30분 추가');

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '카페 아메리카노 교환권', '가상카페 아메리카노 1잔 모바일 교환권', 'COUPON', 4500, 200, 0, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '카페 아메리카노 교환권');

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '영화 관람권 1매', '가상시네마 2D 일반 관람권', 'COUPON', 9000, 50, 1, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '영화 관람권 1매');

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT 'L∞P 에코백', 'L∞P 로고 캔버스 에코백 (가상 배송)', 'GOODS', 6000, 30, 1, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = 'L∞P 에코백');

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '보조배터리 10000mAh', 'L∞P 로고 보조배터리 (가상 배송)', 'GOODS', 25000, 10, 2, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '보조배터리 10000mAh');

INSERT INTO shop_items (name, description, category, price_points, stock, min_tier_rank, is_active, created_at, updated_at)
SELECT '데이터 무제한 1일 이용권', '24시간 데이터 무제한 (가상, VIP 전용)', 'DATA', 20000, NULL, 3, 1, UTC_TIMESTAMP(), UTC_TIMESTAMP() FROM DUAL
WHERE NOT EXISTS (SELECT 1 FROM shop_items WHERE name = '데이터 무제한 1일 이용권');

SELECT id, name, price_points, stock, min_tier_rank FROM shop_items ORDER BY min_tier_rank, price_points;
