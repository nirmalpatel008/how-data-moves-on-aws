-- ============================================================
-- How Data Moves on AWS: Athena queries
-- Pick database "canteen_db" in the Athena query editor first.
-- Run one query at a time (select it, then click Run).
-- ============================================================


-- ---------- PART A: look at the RAW data (CSV) ----------

-- A1. Peek at the raw data
SELECT * FROM orders LIMIT 10;

-- A2. How many rows came in?
SELECT COUNT(*) AS total_rows FROM orders;

-- A3. Spot the mess: the same item is spelled in many ways
--     ("Vada Pav", "VADA PAV", "vada pav", "  Vada Pav ")
SELECT item, COUNT(*) AS times_seen
FROM orders
GROUP BY item
ORDER BY lower(trim(item)), item;

-- A4. More mess: blank payment modes and cancelled orders (quantity 0)
SELECT
  SUM(CASE WHEN payment_mode IS NULL OR trim(payment_mode) = '' THEN 1 ELSE 0 END) AS blank_payment,
  SUM(CASE WHEN quantity = 0 THEN 1 ELSE 0 END) AS cancelled_orders,
  COUNT(*) - COUNT(DISTINCT order_id) AS duplicate_rows
FROM orders;


-- ---------- PART B: questions on the CLEAN data (Parquet) ----------
-- Run these after the Glue job has finished.

-- B1. Clean data, one name per item
SELECT item, COUNT(*) AS orders
FROM orders_clean
GROUP BY item
ORDER BY orders DESC;

-- B2. What do students order the most?
SELECT item, SUM(quantity) AS plates_or_cups
FROM orders_clean
GROUP BY item
ORDER BY plates_or_cups DESC
LIMIT 5;

-- B3. Which item makes the most money?
SELECT item, SUM(total_amount) AS revenue_inr
FROM orders_clean
GROUP BY item
ORDER BY revenue_inr DESC
LIMIT 5;

-- B4. UPI vs Cash vs Card
SELECT
  payment_mode,
  COUNT(*) AS orders,
  ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 1) AS percent
FROM orders_clean
GROUP BY payment_mode
ORDER BY orders DESC;

-- B5. Rush hour: when is the canteen busiest?
SELECT order_hour, COUNT(*) AS orders
FROM orders_clean
GROUP BY order_hour
ORDER BY order_hour;

-- B6. Sales per day
SELECT order_date, COUNT(*) AS orders, SUM(total_amount) AS revenue_inr
FROM orders_clean
GROUP BY order_date
ORDER BY order_date;

-- B7. Only one day? Partitions mean Athena reads just that day's folder.
SELECT counter, SUM(total_amount) AS revenue_inr
FROM orders_clean
WHERE order_date = '2026-11-18'
GROUP BY counter
ORDER BY revenue_inr DESC;


-- ---------- PART C: why Parquet? ----------
-- Run both, then compare "Data scanned" under the results.
-- Parquet reads only the columns you ask for, so it scans less (and costs less).

-- C1. CSV table
SELECT SUM(quantity * unit_price) AS revenue FROM orders;

-- C2. Parquet table
SELECT SUM(total_amount) AS revenue FROM orders_clean;
