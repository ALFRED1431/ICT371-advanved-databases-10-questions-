-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 3: Library Returns and Overdue Fines (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- Fine rule: K2 per day after the due date; return on due date = no fine.
-- =====================================================================

DROP TABLE IF EXISTS overdue_summary, loan_audit, loans, books CASCADE;

-- ---------------------------------------------------------------------
-- Q3 (a) Database and seed data [6 marks]  -- tables + books
-- ---------------------------------------------------------------------
CREATE TABLE books (
    book_id SERIAL PRIMARY KEY,
    title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
    loan_id       SERIAL PRIMARY KEY,
    book_id       INTEGER       NOT NULL REFERENCES books(book_id),
    borrower_name VARCHAR(100)  NOT NULL,
    borrowed_on   DATE          NOT NULL,
    due_on        DATE          NOT NULL,
    returned_on   DATE          NULL,
    fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
    CONSTRAINT ck_due_after_borrowed CHECK (due_on >= borrowed_on)
);

CREATE TABLE loan_audit (
    audit_id          SERIAL PRIMARY KEY,
    loan_id           INTEGER   NOT NULL REFERENCES loans(loan_id),
    old_returned_on   DATE      NULL,
    new_returned_on   DATE      NULL,
    changed_at        TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
    snapshot_date DATE PRIMARY KEY,
    overdue_count INTEGER       NOT NULL DEFAULT 0,
    total_fine    NUMERIC(12,2) NOT NULL DEFAULT 0
);

INSERT INTO books (title) VALUES
    ('Database System Concepts'),
    ('Introduction to Algorithms'),
    ('Computer Networks');

-- ---------------------------------------------------------------------
-- Q3 (b) Function fn_loan_fine [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INTEGER, p_as_of DATE)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_due      DATE;
    v_returned DATE;
    v_end      DATE;
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    SELECT due_on, returned_on INTO v_due, v_returned
    FROM loans
    WHERE loan_id = p_loan_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;

    -- earlier of p_as_of and returned_on (when a return date exists)
    v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));

    RETURN 2 * GREATEST(v_end - v_due, 0);      -- K2 per overdue day, min 0
END;
$$;

-- ---------------------------------------------------------------------
-- Q3 (c) Procedure pr_return_loan [8 marks]
-- Return date and final fine are stored in ONE update.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INTEGER, p_returned_on DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_borrowed DATE;
    v_returned DATE;
    v_fine     NUMERIC(10,2);
BEGIN
    IF p_returned_on IS NULL THEN
        RAISE EXCEPTION 'Return date must not be NULL';
    END IF;

    SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
    FROM loans
    WHERE loan_id = p_loan_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown loan_id: %', p_loan_id;
    END IF;
    IF v_returned IS NOT NULL THEN
        RAISE EXCEPTION 'Loan % was already returned on %', p_loan_id, v_returned;
    END IF;
    IF p_returned_on < v_borrowed THEN
        RAISE EXCEPTION 'Return date % is before borrow date %', p_returned_on, v_borrowed;
    END IF;

    v_fine := fn_loan_fine(p_loan_id, p_returned_on);

    UPDATE loans
       SET returned_on = p_returned_on,
           fine_amount = v_fine
     WHERE loan_id = p_loan_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Q3 (d) Trigger on loans [8 marks]
-- AFTER UPDATE row trigger; logs only real changes of returned_on.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_loan_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on, changed_at)
    VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_fn_loan_audit();

-- ---------------------------------------------------------------------
-- Q3 (a) continued: six loans (dates relative to today so the data is
-- always meaningful), then two are returned through the procedure.
-- ---------------------------------------------------------------------
INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
    (1, 'Mwansa Banda',   CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 1 open, overdue (16 days)
    (1, 'Temwa Phiri',    CURRENT_DATE - 5,  CURRENT_DATE + 9),   -- 2 open, on time
    (2, 'Chanda Mulenga', CURRENT_DATE - 40, CURRENT_DATE - 26),  -- 3 to be returned late
    (2, 'Natasha Zulu',   CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 4 to be returned ON due date
    (3, 'Joseph Tembo',   CURRENT_DATE - 12, CURRENT_DATE - 2),   -- 5 open, overdue (2 days)
    (3, 'Grace Lungu',    CURRENT_DATE - 14, CURRENT_DATE);       -- 6 open, due today (no fine)

CALL pr_return_loan(3, CURRENT_DATE - 20);   -- 6 days late  -> K12
CALL pr_return_loan(4, CURRENT_DATE - 6);    -- on due date  -> K0

SELECT * FROM loans ORDER BY loan_id;
SELECT * FROM loan_audit ORDER BY audit_id;    -- 2 rows

-- Rejection tests
DO $$ BEGIN CALL pr_return_loan(3, CURRENT_DATE);       -- already returned
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(999, CURRENT_DATE);     -- unknown loan
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_return_loan(1, CURRENT_DATE - 31);  -- before borrowed_on
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Same-value update must NOT create an audit row
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;
SELECT COUNT(*) AS audit_rows_still_2 FROM loan_audit;

-- ---------------------------------------------------------------------
-- Q3 (e) View v_overdue_loans [5 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM   loans l
JOIN   books b ON b.book_id = l.book_id
WHERE  l.returned_on IS NULL
  AND  l.due_on < CURRENT_DATE;

SELECT * FROM v_overdue_loans ORDER BY loan_id;

-- ---------------------------------------------------------------------
-- Q3 (f) Index [5 marks]
-- Partial index on book_id covering only UNRETURNED loans: it is small
-- (returned loans never enter it) and exactly matches the search.
-- ---------------------------------------------------------------------
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
ANALYZE loans;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT loan_id, borrower_name, due_on
FROM   loans
WHERE  book_id = 1
  AND  returned_on IS NULL;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q3 (g) Scheduled job [6 marks]
-- Counts loans that are OVERDUE and still unreturned as of p_as_of, and
-- sums their fines as of that date. Same snapshot_date is replaced.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_as_of IS NULL THEN
        RAISE EXCEPTION 'p_as_of must not be NULL';
    END IF;

    INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
    SELECT p_as_of,
           COUNT(*),
           COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
    FROM   loans
    WHERE  borrowed_on <= p_as_of
      AND  (returned_on IS NULL OR returned_on > p_as_of)   -- unreturned as of that date
      AND  due_on < p_as_of                                 -- and overdue
    ON CONFLICT (snapshot_date) DO UPDATE
        SET overdue_count = EXCLUDED.overdue_count,
            total_fine    = EXCLUDED.total_fine;
END;
$$;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);     -- rerun replaces the same snapshot_date
SELECT * FROM overdue_summary;             -- 2 loans, K32 + K4 = K36

-- Daily at 00:10 for CURRENT_DATE (pg_cron uses UTC unless configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_overdue_daily', '10 0 * * *',
                     $$CALL pr_refresh_overdue(CURRENT_DATE)$$);
