-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 9: Farmer Cooperative Maize Deliveries (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- Rates: grade A = K5/kg, B = K4/kg, C = K3/kg.
-- =====================================================================

DROP TABLE IF EXISTS daily_purchases, deliveries, farmers CASCADE;

-- ---------------------------------------------------------------------
-- Q9 (a) Database and seed data [6 marks]  -- tables + farmers
-- ---------------------------------------------------------------------
CREATE TABLE farmers (
    farmer_id     SERIAL PRIMARY KEY,
    farmer_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
    delivery_id  SERIAL PRIMARY KEY,
    farmer_id    INTEGER       NOT NULL REFERENCES farmers(farmer_id),
    grade        CHAR(1)       NOT NULL CHECK (grade IN ('A', 'B', 'C')),
    weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
    unit_rate    NUMERIC(10,2) NOT NULL,          -- filled in by the trigger
    total_value  NUMERIC(12,2) NOT NULL,          -- filled in by the trigger
    delivered_on DATE          NOT NULL DEFAULT CURRENT_DATE,
    is_paid      BOOLEAN       NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
    purchase_date DATE PRIMARY KEY,
    total_weight  NUMERIC(12,2) NOT NULL DEFAULT 0,
    total_value   NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO farmers (farmer_number, full_name) VALUES
    ('F001', 'Mwansa Banda'),
    ('F002', 'Temwa Phiri'),
    ('F003', 'Chanda Mulenga');

-- ---------------------------------------------------------------------
-- Q9 (b) Function fn_maize_rate [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
    v_rate NUMERIC(10,2);
BEGIN
    IF p_grade IS NULL THEN
        RAISE EXCEPTION 'Grade must not be NULL';
    END IF;

    IF    p_grade = 'A' THEN v_rate := 5.00;
    ELSIF p_grade = 'B' THEN v_rate := 4.00;
    ELSIF p_grade = 'C' THEN v_rate := 3.00;
    ELSE
        RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
    END IF;

    RETURN v_rate;
END;
$$;

-- ---------------------------------------------------------------------
-- Q9 (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE: rejects non-positive weight, then sets
-- unit_rate and total_value from fn_maize_rate. Applies to direct SQL too,
-- so any value supplied by the caller for these columns is overwritten.
-- (Created before the procedure and the seed data, which depend on it.)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_delivery_pricing()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
        RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
    END IF;

    NEW.unit_rate   := fn_maize_rate(NEW.grade);
    NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_fn_delivery_pricing();

-- ---------------------------------------------------------------------
-- Q9 (c) Procedure pr_receive_delivery [8 marks]
-- Inserts only the basic fields; the trigger supplies unit_rate/total_value.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_delivery(
    p_farmer_id INTEGER,
    p_grade     VARCHAR,
    p_weight    NUMERIC,
    p_date      DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
        RAISE EXCEPTION 'Unknown farmer_id: %', p_farmer_id;
    END IF;
    IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
        RAISE EXCEPTION 'Invalid grade: % (use A, B or C)', p_grade;
    END IF;
    IF p_weight IS NULL OR p_weight <= 0 THEN
        RAISE EXCEPTION 'Invalid weight: % (must be positive)', p_weight;
    END IF;
    IF p_date IS NULL THEN
        RAISE EXCEPTION 'Delivery date must not be NULL';
    END IF;

    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
    VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END;
$$;

-- ---------------------------------------------------------------------
-- Q9 (a) continued: six deliveries (all grades, paid and unpaid),
-- loaded AFTER the trigger was installed.
-- ---------------------------------------------------------------------
CALL pr_receive_delivery(1, 'A', 100, CURRENT_DATE - 1);        -- unpaid, K500
CALL pr_receive_delivery(1, 'B',  50, CURRENT_DATE - 1);        -- unpaid, K200
CALL pr_receive_delivery(2, 'C', 200, CURRENT_DATE);            -- unpaid, K600
CALL pr_receive_delivery(2, 'A',  80, CURRENT_DATE);            -- unpaid, K400

-- Paid deliveries by direct SQL: the trigger still applies the pricing rule.
-- The wrong unit_rate/total_value supplied for the last row is overwritten.
INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid)
VALUES (3, 'B', 120, 4.00, 480.00, CURRENT_DATE - 1, TRUE),
       (2, 'C',  60, 99.00,  1.00, CURRENT_DATE - 1, TRUE);    -- corrected to 3.00 / 180.00

SELECT * FROM deliveries ORDER BY delivery_id;

-- Tests
SELECT fn_maize_rate('A') AS a, fn_maize_rate('B') AS b, fn_maize_rate('C') AS c;
DO $$ BEGIN PERFORM fn_maize_rate(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_maize_rate('D');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);      -- unknown farmer
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);        -- zero weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_delivery(1, 'X', 10, CURRENT_DATE);       -- bad grade
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN
    INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
    VALUES (1, 'A', -5, CURRENT_DATE);                                -- direct SQL, bad weight
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------
-- Q9 (e) View v_farmer_amount_due [5 marks]
-- LEFT JOIN with the unpaid condition in ON keeps farmers with no unpaid
-- deliveries; COALESCE shows their amount as zero.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0) AS amount_due
FROM   farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- F003 shows 0

-- ---------------------------------------------------------------------
-- Q9 (f) Index [5 marks]
-- Composite (farmer_id, delivered_on): equality on the farmer first and
-- the date range second, so one farmer's deliveries between two dates are
-- adjacent in the B-tree.
-- ---------------------------------------------------------------------
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
ANALYZE deliveries;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT delivery_id, grade, weight_kg, total_value
FROM   deliveries
WHERE  farmer_id = 1
  AND  delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q9 (g) Scheduled job [6 marks]
-- Totals are recomputed from deliveries and REPLACE the stored row.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
    SELECT p_day,
           COALESCE(SUM(weight_kg), 0),
           COALESCE(SUM(total_value), 0)
    FROM   deliveries
    WHERE  delivered_on = p_day
    ON CONFLICT (purchase_date) DO UPDATE
        SET total_weight = EXCLUDED.total_weight,
            total_value  = EXCLUDED.total_value;
END;
$$;

CALL pr_refresh_purchases(CURRENT_DATE - 1);
CALL pr_refresh_purchases(CURRENT_DATE - 1);    -- rerun: replaced, not doubled
SELECT * FROM daily_purchases;

-- Daily at 01:30 for the previous day (pg_cron uses UTC unless configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_purchases_daily', '30 1 * * *',
                     $$CALL pr_refresh_purchases(CURRENT_DATE - 1)$$);
