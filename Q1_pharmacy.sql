-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 1: Pharmacy Stock and Daily Sales (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- =====================================================================

DROP TABLE IF EXISTS daily_sales, stock_audit, sales, medicines CASCADE;

-- ---------------------------------------------------------------------
-- Q1 (a) Database and seed data [6 marks]  -- tables + medicines
-- ---------------------------------------------------------------------
CREATE TABLE medicines (
    medicine_id   SERIAL PRIMARY KEY,
    medicine_name VARCHAR(100)  NOT NULL UNIQUE,
    unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    stock_qty     INTEGER       NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
    sale_id     SERIAL PRIMARY KEY,
    medicine_id INTEGER       NOT NULL REFERENCES medicines(medicine_id),
    quantity    INTEGER       NOT NULL CHECK (quantity > 0),
    unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
    sold_on     DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE stock_audit (
    audit_id    SERIAL PRIMARY KEY,
    medicine_id INTEGER   NOT NULL REFERENCES medicines(medicine_id),
    old_qty     INTEGER   NOT NULL,
    new_qty     INTEGER   NOT NULL,
    changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
    sales_date   DATE PRIMARY KEY,
    total_qty    INTEGER       NOT NULL DEFAULT 0,
    total_amount NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Seed medicines (four medicines; sales are loaded later via the procedure)
INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
    ('Paracetamol 500mg', 2.50, 100),
    ('Amoxicillin 250mg', 15.00, 40),
    ('Ibuprofen 400mg',   4.75, 12),
    ('Cough Syrup 100ml', 22.00, 8);

-- ---------------------------------------------------------------------
-- Q1 (b) Function fn_sale_value [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INTEGER, p_quantity INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_price NUMERIC(10,2);
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be a positive number)', p_quantity;
    END IF;

    SELECT unit_price INTO v_price
    FROM medicines
    WHERE medicine_id = p_medicine_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    RETURN v_price * p_quantity;
END;
$$;

-- ---------------------------------------------------------------------
-- Q1 (c) Procedure pr_record_sale [8 marks]
-- Row is locked (FOR UPDATE) so stock cannot be oversold; any exception
-- rolls back everything, leaving sales and medicines unchanged.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_sale(
    p_medicine_id INTEGER,
    p_quantity    INTEGER,
    p_sold_on     DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_price NUMERIC(10,2);
    v_stock INTEGER;
BEGIN
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'Invalid quantity: % (must be positive)', p_quantity;
    END IF;
    IF p_sold_on IS NULL THEN
        RAISE EXCEPTION 'Sale date must not be NULL';
    END IF;

    SELECT unit_price, stock_qty
      INTO v_price, v_stock
      FROM medicines
     WHERE medicine_id = p_medicine_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown medicine_id: %', p_medicine_id;
    END IF;

    IF v_stock < p_quantity THEN
        RAISE EXCEPTION 'Insufficient stock for medicine %: requested %, available %',
                        p_medicine_id, p_quantity, v_stock;
    END IF;

    -- store the CURRENT price in the sale
    INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
    VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);

    -- deduct stock exactly once
    UPDATE medicines
       SET stock_qty = stock_qty - p_quantity
     WHERE medicine_id = p_medicine_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Q1 (d) Trigger on medicines [8 marks]
-- AFTER UPDATE row trigger; fires only when stock_qty really changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_stock_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO stock_audit (medicine_id, old_qty, new_qty, changed_at)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_fn_stock_audit();

-- ---------------------------------------------------------------------
-- Q1 (a) continued: six valid sales loaded THROUGH the procedure
-- ---------------------------------------------------------------------
CALL pr_record_sale(1, 10, CURRENT_DATE - 1);   -- Paracetamol
CALL pr_record_sale(1,  5, CURRENT_DATE - 1);   -- Paracetamol
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);   -- Amoxicillin
CALL pr_record_sale(3,  5, CURRENT_DATE);       -- Ibuprofen (stock 12 -> 7)
CALL pr_record_sale(4,  2, CURRENT_DATE);       -- Cough syrup (8 -> 6)
CALL pr_record_sale(2,  5, CURRENT_DATE);       -- Amoxicillin

SELECT * FROM sales ORDER BY sale_id;
SELECT * FROM stock_audit ORDER BY audit_id;     -- 6 rows: trigger worked

-- Test: invalid sales leave data unchanged
DO $$
BEGIN
    CALL pr_record_sale(3, 1000, CURRENT_DATE);   -- more than stock
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;
DO $$
BEGIN
    CALL pr_record_sale(999, 1, CURRENT_DATE);    -- unknown medicine
EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'Rejected as expected: %', SQLERRM;
END $$;
SELECT fn_sale_value(1, 4) AS value_of_4_paracetamol;   -- 10.00

-- ---------------------------------------------------------------------
-- Q1 (e) View v_low_stock [5 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_id,
       medicine_name,
       unit_price,
       stock_qty AS remaining_stock
FROM   medicines
WHERE  stock_qty < 10;

-- Query the view after the sales (Ibuprofen 7 and Cough Syrup 6 appear)
SELECT * FROM v_low_stock ORDER BY medicine_name;

-- ---------------------------------------------------------------------
-- Q1 (f) Index [5 marks]
-- Composite (medicine_id, sold_on): equality column first, range column
-- second, so one B-tree descent finds the medicine and scans only the
-- requested date range in order.
-- ---------------------------------------------------------------------
CREATE INDEX idx_sales_medicine_sold_on ON sales (medicine_id, sold_on);
ANALYZE sales;

-- seqscan disabled only because the demo table is tiny
SET enable_seqscan = OFF;
EXPLAIN
SELECT sale_id, quantity, unit_price, sold_on
FROM   sales
WHERE  medicine_id = 1
  AND  sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q1 (g) Scheduled job [6 marks]
-- Upsert makes reruns idempotent: values are REPLACED, never added.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_sales (sales_date, total_qty, total_amount)
    SELECT p_day,
           COALESCE(SUM(quantity), 0),
           COALESCE(SUM(quantity * unit_price), 0)
    FROM   sales
    WHERE  sold_on = p_day
    ON CONFLICT (sales_date) DO UPDATE
        SET total_qty    = EXCLUDED.total_qty,
            total_amount = EXCLUDED.total_amount;
END;
$$;

-- Run twice to prove no duplication / double counting
CALL pr_refresh_sales(CURRENT_DATE - 1);
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT * FROM daily_sales;     -- yesterday: qty 25, amount 62.50+... recomputed

-- Schedule daily at 00:15 for the previous day (pg_cron uses UTC unless
-- cron.timezone is configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_sales_daily', '15 0 * * *',
                     $$CALL pr_refresh_sales(CURRENT_DATE - 1)$$);
