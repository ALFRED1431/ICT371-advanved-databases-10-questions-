-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 7: Water Meter Readings and Billing (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- Tariff: first 10 units K5 each; units above 10 K8 each; 0 units = K0.
-- =====================================================================

DROP TABLE IF EXISTS receivable_snapshot, bills, readings, customers CASCADE;

-- ---------------------------------------------------------------------
-- Q7 (a) Database and seed data [6 marks]  -- tables + customers
-- ---------------------------------------------------------------------
CREATE TABLE customers (
    customer_id SERIAL PRIMARY KEY,
    full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
    reading_id       SERIAL PRIMARY KEY,
    customer_id      INTEGER       NOT NULL REFERENCES customers(customer_id),
    reading_month    DATE          NOT NULL,
    previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
    current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading  >= 0),
    CONSTRAINT ck_reading_month_first_day CHECK (EXTRACT(DAY FROM reading_month) = 1),
    CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
    bill_id     SERIAL PRIMARY KEY,
    reading_id  INTEGER       NOT NULL UNIQUE REFERENCES readings(reading_id),
    charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
    amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
    due_on      DATE          NOT NULL,
    CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
    snapshot_date DATE PRIMARY KEY,
    total_due     NUMERIC(14,2) NOT NULL DEFAULT 0
);

INSERT INTO customers (full_name) VALUES
    ('Mwansa Banda'), ('Temwa Phiri'), ('Chanda Mulenga');

-- ---------------------------------------------------------------------
-- Q7 (b) Function fn_water_charge [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2)
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_units IS NULL OR p_units < 0 THEN
        RAISE EXCEPTION 'Invalid consumption: % (must be non-negative)', p_units;
    END IF;

    IF p_units <= 10 THEN
        RETURN ROUND(p_units * 5, 2);
    END IF;
    RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END;
$$;

-- ---------------------------------------------------------------------
-- Q7 (c) Procedure pr_generate_bill [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INTEGER, p_due_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_prev   NUMERIC(12,2);
    v_curr   NUMERIC(12,2);
    v_units  NUMERIC(12,2);
    v_charge NUMERIC(12,2);
BEGIN
    IF p_due_on IS NULL THEN
        RAISE EXCEPTION 'Due date must not be NULL';
    END IF;

    SELECT previous_reading, current_reading
      INTO v_prev, v_curr
      FROM readings
     WHERE reading_id = p_reading_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown reading_id: %', p_reading_id;
    END IF;
    IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
        RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
    END IF;

    v_units  := v_curr - v_prev;
    v_charge := fn_water_charge(v_units);

    INSERT INTO bills (reading_id, charge, amount_paid, due_on)
    VALUES (p_reading_id, v_charge, 0, p_due_on);
END;
$$;

-- ---------------------------------------------------------------------
-- Q7 (d) Trigger on readings [8 marks]
-- BEFORE INSERT OR UPDATE: a rejected reading is never stored.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_reading_check()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.current_reading < NEW.previous_reading THEN
        RAISE EXCEPTION 'current_reading (%) cannot be below previous_reading (%)',
                        NEW.current_reading, NEW.previous_reading;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_fn_reading_check();

-- ---------------------------------------------------------------------
-- Q7 (a) continued: six readings (0 units, exactly 10, above 10)
-- ---------------------------------------------------------------------
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
    (1, '2026-09-01', 100.00, 100.00),   -- 0 units   -> K0
    (1, '2026-10-01', 100.00, 110.00),   -- 10 units  -> K50
    (2, '2026-09-01',  50.00,  75.00),   -- 25 units  -> K170
    (2, '2026-10-01',  75.00,  79.00),   -- 4 units   -> K20
    (3, '2026-09-01', 200.00, 210.00),   -- 10 units  -> K50
    (3, '2026-10-01', 210.00, 222.50);   -- 12.5 units-> K70

-- Trigger tests: rejected rows are not stored
DO $$ BEGIN
    INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
    VALUES (1, '2026-11-01', 110.00, 105.00);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN
    UPDATE readings SET current_reading = 1 WHERE reading_id = 2;    -- below previous (100)
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
SELECT COUNT(*) AS readings_should_be_6 FROM readings;

-- Function tests
SELECT fn_water_charge(0) AS zero, fn_water_charge(10) AS ten,
       fn_water_charge(25) AS twenty_five, fn_water_charge(12.5) AS twelve_half;
DO $$ BEGIN PERFORM fn_water_charge(NULL);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_water_charge(-1);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Generate bills through the procedure (readings 1-5)
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 15);
CALL pr_generate_bill(3, CURRENT_DATE - 10);
CALL pr_generate_bill(4, CURRENT_DATE + 5);
CALL pr_generate_bill(5, CURRENT_DATE - 3);

-- Record some payments (constraint keeps 0 <= amount_paid <= charge)
UPDATE bills SET amount_paid = charge WHERE bill_id = 2;    -- fully paid
UPDATE bills SET amount_paid = 70     WHERE bill_id = 3;    -- part paid, overdue

-- Rejection tests
DO $$ BEGIN CALL pr_generate_bill(2, CURRENT_DATE);       -- already billed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_generate_bill(999, CURRENT_DATE);     -- unknown reading
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN UPDATE bills SET amount_paid = 9999 WHERE bill_id = 4;   -- exceeds charge
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_generate_bill(6, CURRENT_DATE + 10);              -- last reading
SELECT * FROM bills ORDER BY bill_id;

-- ---------------------------------------------------------------------
-- Q7 (e) View v_overdue_bills [5 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM   bills b
JOIN   readings r ON r.reading_id  = b.reading_id
JOIN   customers c ON c.customer_id = r.customer_id
WHERE  b.due_on < CURRENT_DATE
  AND  b.amount_paid < b.charge;

SELECT * FROM v_overdue_bills ORDER BY due_on;     -- bills 3 (K100) and 5 (K50)

-- ---------------------------------------------------------------------
-- Q7 (f) Index [5 marks]
-- Partial index on due_on containing only UNPAID bills. Overdue searches
-- only care about unpaid bills, so settled bills (the majority over time)
-- stay out of the index, which stays small and the due_on range scan is fast.
-- ---------------------------------------------------------------------
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
ANALYZE bills;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT bill_id, due_on, charge - amount_paid AS outstanding
FROM   bills
WHERE  amount_paid < charge
  AND  due_on < CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q7 (g) Scheduled job [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO receivable_snapshot (snapshot_date, total_due)
    SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
    FROM   bills
    WHERE  amount_paid < charge
    ON CONFLICT (snapshot_date) DO UPDATE
        SET total_due = EXCLUDED.total_due;       -- replaced, never added
END;
$$;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();      -- rerun: same single row for today
SELECT * FROM receivable_snapshot;

-- Daily at 00:30 (pg_cron uses UTC unless cron.timezone is configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_receivables_daily', '30 0 * * *',
                     $$CALL pr_refresh_receivables()$$);
