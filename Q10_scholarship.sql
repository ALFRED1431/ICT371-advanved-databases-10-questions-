-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 10: Scholarship Application Assessment (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- Eligible only if: age 18-25 inclusive AND income <= K3,000 AND mark >= 70.
-- =====================================================================

DROP TABLE IF EXISTS decision_audit, applications, students CASCADE;

-- ---------------------------------------------------------------------
-- Q10 (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
    application_id      SERIAL PRIMARY KEY,
    student_id          INTEGER       NOT NULL REFERENCES students(student_id),
    age_at_application  INTEGER       NOT NULL CHECK (age_at_application > 0),
    monthly_income      NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
    average_mark        NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
    submitted_on        DATE          NOT NULL DEFAULT CURRENT_DATE,
    status              VARCHAR(10)   NOT NULL DEFAULT 'PENDING',
    CONSTRAINT ck_app_status CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);

CREATE TABLE decision_audit (
    audit_id       SERIAL PRIMARY KEY,
    application_id INTEGER     NOT NULL REFERENCES applications(application_id),
    old_status     VARCHAR(10) NOT NULL,
    new_status     VARCHAR(10) NOT NULL,
    changed_at     TIMESTAMP   NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
    ('202400001', 'Mwansa Banda'),
    ('202400002', 'Temwa Phiri'),
    ('202400003', 'Chanda Mulenga');

-- Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
    (1, 20, 2000.00, 80.00, CURRENT_DATE - 10, 'PENDING'),   -- 1 qualifies
    (1, 18, 3000.00, 70.00, CURRENT_DATE -  9, 'PENDING'),   -- 2 boundary: all minimums -> qualifies
    (2, 25, 1500.00, 95.00, CURRENT_DATE -  8, 'PENDING'),   -- 3 boundary: max age -> qualifies
    (2, 17, 1000.00, 90.00, CURRENT_DATE -  7, 'PENDING'),   -- 4 too young -> rejected
    (3, 22, 3001.00, 85.00, CURRENT_DATE -  6, 'PENDING'),   -- 5 income K3,001 -> rejected
    (3, 24, 2500.00, 69.99, CURRENT_DATE -  5, 'PENDING');   -- 6 mark 69.99 -> rejected

-- ---------------------------------------------------------------------
-- Q10 (b) Function fn_scholarship_eligible [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(
    p_age    INTEGER,
    p_income NUMERIC,
    p_mark   NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql IMMUTABLE
AS $$
BEGIN
    IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
        RAISE EXCEPTION 'Age, income and mark must not be NULL';
    END IF;
    IF p_age <= 0 THEN
        RAISE EXCEPTION 'Invalid age: % (must be positive)', p_age;
    END IF;
    IF p_income < 0 THEN
        RAISE EXCEPTION 'Invalid income: % (must not be negative)', p_income;
    END IF;
    IF p_mark < 0 OR p_mark > 100 THEN
        RAISE EXCEPTION 'Invalid mark: % (must be between 0 and 100)', p_mark;
    END IF;

    RETURN p_age BETWEEN 18 AND 25
       AND p_income <= 3000
       AND p_mark   >= 70;
END;
$$;

-- ---------------------------------------------------------------------
-- Q10 (c) Procedure pr_assess_application [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INTEGER)
LANGUAGE plpgsql
AS $$
DECLARE
    v_age    INTEGER;
    v_income NUMERIC(12,2);
    v_mark   NUMERIC(5,2);
    v_status VARCHAR(10);
BEGIN
    SELECT age_at_application, monthly_income, average_mark, status
      INTO v_age, v_income, v_mark, v_status
      FROM applications
     WHERE application_id = p_application_id
       FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown application_id: %', p_application_id;
    END IF;
    IF v_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Application % was already assessed (status %)', p_application_id, v_status;
    END IF;

    UPDATE applications
       SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                         THEN 'APPROVED' ELSE 'REJECTED' END
     WHERE application_id = p_application_id;
END;
$$;

-- ---------------------------------------------------------------------
-- Q10 (d) Trigger on applications [8 marks]
-- AFTER UPDATE row trigger; audit row only when status really changes.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_decision_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
    VALUES (OLD.application_id, OLD.status, NEW.status, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_fn_decision_audit();

-- Tests for (b) and (c)
SELECT fn_scholarship_eligible(18, 3000, 70)   AS boundary_true,
       fn_scholarship_eligible(26, 1000, 90)   AS too_old_false,
       fn_scholarship_eligible(20, 3000.01, 90) AS income_false;
DO $$ BEGIN PERFORM fn_scholarship_eligible(NULL, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, -1, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(0, 1000, 80);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_scholarship_eligible(20, 1000, 101);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

CALL pr_assess_application(1);                                  -- APPROVED
DO $$ BEGIN CALL pr_assess_application(1);                      -- already assessed
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_assess_application(999);                    -- unknown
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- An UPDATE that leaves the status unchanged creates NO audit row
UPDATE applications SET status = status WHERE application_id = 1;
SELECT * FROM decision_audit ORDER BY audit_id;                 -- exactly 1 row

-- ---------------------------------------------------------------------
-- Q10 (e) View v_approved_applicants [5 marks]
-- Income is deliberately omitted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM   applications a
JOIN   students s ON s.student_id = a.student_id
WHERE  a.status = 'APPROVED';

-- ---------------------------------------------------------------------
-- Q10 (f) Index [5 marks]
-- Composite (status, submitted_on): equality on status first, then the
-- submitted_on range, so matching rows are adjacent in the B-tree.
-- ---------------------------------------------------------------------
CREATE INDEX idx_app_status_submitted ON applications (status, submitted_on);
ANALYZE applications;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT application_id, student_id, submitted_on
FROM   applications
WHERE  status = 'PENDING'
  AND  submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q10 (g) Scheduled job [6 marks]
-- Query FOR loop over PENDING rows only (FOR UPDATE SKIP LOCKED avoids
-- clashing with another session). Completed applications are never
-- selected, so reruns do not reassess them or duplicate audit rows.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql
AS $$
DECLARE
    rec RECORD;
BEGIN
    FOR rec IN
        SELECT application_id
        FROM   applications
        WHERE  status = 'PENDING'
        ORDER  BY application_id
        FOR UPDATE SKIP LOCKED
    LOOP
        CALL pr_assess_application(rec.application_id);
    END LOOP;
END;
$$;

CALL pr_assess_pending();      -- assesses applications 2-6
CALL pr_assess_pending();      -- rerun: nothing pending, no changes

SELECT application_id, status FROM applications ORDER BY application_id;
SELECT * FROM decision_audit ORDER BY audit_id;       -- exactly 6 rows, no duplicates
SELECT * FROM v_approved_applicants ORDER BY student_number;   -- applications 1, 2, 3

-- Every Monday at 08:00 (pg_cron uses UTC unless cron.timezone is configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('assess_pending_weekly', '0 8 * * 1',
                     $$CALL pr_assess_pending()$$);
