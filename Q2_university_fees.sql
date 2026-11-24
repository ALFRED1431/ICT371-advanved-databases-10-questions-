-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 2: University Fee Payments (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- =====================================================================

DROP TABLE IF EXISTS daily_collections, payment_audit, payments, students CASCADE;

-- ---------------------------------------------------------------------
-- Q2 (a) Database and seed data [6 marks]  -- tables + students
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)   NOT NULL UNIQUE,
    full_name      VARCHAR(100)  NOT NULL,
    fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    paid_on    DATE          NOT NULL DEFAULT CURRENT_DATE
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER       NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER       NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12,2) NOT NULL,
    logged_at  TIMESTAMP     NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER       NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12,2) NOT NULL DEFAULT 0
);

-- Three students with different balances (payments loaded later)
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('202400001', 'Mwansa Banda',   5000.00),
    ('202400002', 'Temwa Phiri',    3000.00),
    ('202400003', 'Chanda Mulenga', 4000.00);   -- will have NO payments

-- ---------------------------------------------------------------------
-- Q2 (b) Function fn_fee_balance [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_fee  NUMERIC(12,2);
    v_paid NUMERIC(12,2);
BEGIN
    SELECT fee_due INTO v_fee
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee - v_paid;      -- full fee when there are no payments
END;
$$;

-- ---------------------------------------------------------------------
-- Q2 (c) Procedure pr_receive_payment [8 marks]
-- Does NOT write to payment_audit (the trigger does) and never touches fee_due.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC,
    p_paid_on    DATE DEFAULT CURRENT_DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12,2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Invalid payment amount: % (must be greater than zero)', p_amount;
    END IF;
    IF p_paid_on IS NULL THEN
        RAISE EXCEPTION 'Payment date must not be NULL';
    END IF;

    -- lock the student row so two concurrent payments cannot overpay
    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);
    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
                        p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- ---------------------------------------------------------------------
-- Q2 (d) Trigger on payments [8 marks]
-- AFTER INSERT row trigger writes the audit record automatically.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_payment_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_payment_audit();

-- ---------------------------------------------------------------------
-- Q2 (a) continued: seven payments through the procedure
-- Student 1 owes 700 afterwards, student 2 is fully settled,
-- student 3 has no payments.
-- ---------------------------------------------------------------------
CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1,  300.00, CURRENT_DATE);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE);

SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;   -- 7 rows, written by trigger
SELECT student_id, fn_fee_balance(student_id) AS balance FROM students ORDER BY 1;

-- Rejection tests
DO $$ BEGIN CALL pr_receive_payment(3, NULL, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 0, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, -50, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_receive_payment(3, 4500, CURRENT_DATE);     -- above balance
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_fee_balance(999);                         -- unknown student
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------
-- Q2 (e) View v_fee_balances [5 marks]
-- Settled students (balance = 0) are excluded.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM   students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

SELECT * FROM v_fee_balances ORDER BY student_number;

-- ---------------------------------------------------------------------
-- Q2 (f) Index [5 marks]
-- Composite (student_id, paid_on): equality on student_id first, then the
-- paid_on range, so the matching rows are contiguous in the B-tree.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);
ANALYZE payments;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT payment_id, amount, paid_on
FROM   payments
WHERE  student_id = 1
  AND  paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q2 (g) Scheduled job [6 marks]
-- Upsert replaces an existing summary row when rerun.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
    FROM   payments
    WHERE  paid_on = p_day
    ON CONFLICT (collection_date) DO UPDATE
        SET payment_count = EXCLUDED.payment_count,
            total_amount  = EXCLUDED.total_amount;
END;
$$;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);     -- rerun: replaced, not duplicated
SELECT * FROM daily_collections;

-- Daily at 01:00 for the previous day (pg_cron uses UTC unless configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_collections_daily', '0 1 * * *',
                     $$CALL pr_refresh_collections(CURRENT_DATE - 1)$$);
