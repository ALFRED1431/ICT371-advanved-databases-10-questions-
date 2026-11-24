-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 6: Monthly Payroll Processing (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- gross = basic_salary + allowance ; net = gross - deduction
-- =====================================================================

DROP TABLE IF EXISTS salary_audit, payroll, employees CASCADE;

-- ---------------------------------------------------------------------
-- Q6 (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE employees (
    employee_id  SERIAL PRIMARY KEY,
    full_name    VARCHAR(100)  NOT NULL,
    basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
    allowance    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (allowance >= 0),
    deduction    NUMERIC(12,2) NOT NULL DEFAULT 0 CHECK (deduction >= 0),
    active       BOOLEAN       NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
    payroll_id  SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    pay_month   DATE          NOT NULL,
    gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
    net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
    CONSTRAINT ck_pay_month_first_day CHECK (EXTRACT(DAY FROM pay_month) = 1),
    CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
    audit_id    SERIAL PRIMARY KEY,
    employee_id INTEGER       NOT NULL REFERENCES employees(employee_id),
    old_salary  NUMERIC(12,2) NOT NULL,
    new_salary  NUMERIC(12,2) NOT NULL,
    changed_at  TIMESTAMP     NOT NULL DEFAULT now()
);

INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
    ('Mwansa Banda',   5000.00, 500.00, 300.00, TRUE),
    ('Temwa Phiri',    4000.00, 400.00, 250.00, TRUE),
    ('Chanda Mulenga', 3000.00,   0.00, 200.00, FALSE),   -- inactive from the start
    ('Natasha Zulu',   6000.00, 600.00, 400.00, TRUE);    -- becomes inactive later

-- ---------------------------------------------------------------------
-- Q6 (b) Function fn_net_pay [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INTEGER)
RETURNS NUMERIC
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_basic NUMERIC(12,2);
    v_allow NUMERIC(12,2);
    v_ded   NUMERIC(12,2);
    v_net   NUMERIC(12,2);
BEGIN
    SELECT basic_salary, allowance, deduction
      INTO v_basic, v_allow, v_ded
      FROM employees
     WHERE employee_id = p_employee_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown employee_id: %', p_employee_id;
    END IF;

    v_net := (v_basic + v_allow) - v_ded;
    IF v_net < 0 THEN
        RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
    END IF;

    RETURN v_net;
END;
$$;

-- ---------------------------------------------------------------------
-- Q6 (c) Procedure pr_process_payroll [8 marks]
-- Query FOR loop over active employees. ON CONFLICT DO NOTHING leaves an
-- existing employee/month row unchanged. Any exception (e.g. negative net
-- pay) aborts the whole call, so nothing is inserted.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    rec   RECORD;
    v_net NUMERIC(12,2);
BEGIN
    IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
        RAISE EXCEPTION 'p_month must be the first day of a month, got %', p_month;
    END IF;

    FOR rec IN
        SELECT employee_id, basic_salary, allowance
        FROM   employees
        WHERE  active = TRUE
        ORDER  BY employee_id
    LOOP
        v_net := fn_net_pay(rec.employee_id);       -- raises on invalid calculation

        INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
        VALUES (rec.employee_id, p_month, rec.basic_salary + rec.allowance, v_net)
        ON CONFLICT (employee_id, pay_month) DO NOTHING;
    END LOOP;
END;
$$;

-- ---------------------------------------------------------------------
-- Q6 (d) Trigger on employees [8 marks]
-- AFTER UPDATE; logs only an ACTUAL change of basic_salary.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_salary_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO salary_audit (employee_id, old_salary, new_salary, changed_at)
    VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary, now());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_fn_salary_audit();

-- ---------------------------------------------------------------------
-- Q6 (a) continued: payroll data for two months
-- ---------------------------------------------------------------------
CALL pr_process_payroll('2026-09-01');                    -- employees 1, 2, 4
UPDATE employees SET active = FALSE WHERE employee_id = 4; -- later becomes inactive
CALL pr_process_payroll('2026-10-01');                    -- employees 1, 2

SELECT * FROM payroll ORDER BY pay_month, employee_id;

-- Tests
SELECT fn_net_pay(1) AS net_pay_emp1;                      -- 5200.00

-- salary change is audited; same-value update is not
UPDATE employees SET basic_salary = 5200.00 WHERE employee_id = 1;
UPDATE employees SET basic_salary = 5200.00 WHERE employee_id = 1;   -- no new audit row
UPDATE employees SET allowance   = 500.00  WHERE employee_id = 1;    -- no audit (salary same)
SELECT * FROM salary_audit;                                -- exactly 1 row

-- Rerun September: existing rows remain UNCHANGED (still based on 5000)
CALL pr_process_payroll('2026-09-01');
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;

-- Invalid month and unknown employee
DO $$ BEGIN CALL pr_process_payroll('2026-11-15');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_net_pay(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- Whole call fails if ANY employee's calculation is invalid (nothing inserted)
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active)
VALUES ('Bad Data Test', 100, 0, 500, TRUE);              -- net would be negative
DO $$ BEGIN CALL pr_process_payroll('2026-11-01');
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Whole call failed: %', SQLERRM; END $$;
SELECT COUNT(*) AS november_rows_should_be_0 FROM payroll WHERE pay_month = '2026-11-01';
DELETE FROM employees WHERE full_name = 'Bad Data Test';

-- ---------------------------------------------------------------------
-- Q6 (e) View v_payroll_report [5 marks]
-- Inner join on payroll keeps history even for employees now inactive.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM   payroll p
JOIN   employees e ON e.employee_id = p.employee_id;

SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- ---------------------------------------------------------------------
-- Q6 (f) Index [5 marks]
-- The existing UNIQUE (employee_id, pay_month) index has employee_id as its
-- leading column, so it cannot efficiently serve a filter on pay_month alone.
-- An index on pay_month ONLY (not repeating employee_id) serves the
-- "report for one month across all employees" query without duplicating
-- the unique index.
-- ---------------------------------------------------------------------
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);
ANALYZE payroll;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT employee_id, gross_pay, net_pay
FROM   payroll
WHERE  pay_month = '2026-10-01';
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q6 (g) Scheduled job [6 marks]
-- 02:00 on day 1 of each month, passing the first date of the PREVIOUS month.
-- (pg_cron uses UTC unless cron.timezone is configured)
-- ---------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS pg_cron;

SELECT cron.schedule(
    'monthly_payroll',
    '0 2 1 * *',
    $$CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$
);

-- Inspect the job definition
SELECT jobid, jobname, schedule, command, active
FROM   cron.job
WHERE  jobname = 'monthly_payroll';

-- Inspect the run history (status, message, start/end time)
SELECT d.jobid, d.runid, d.status, d.return_message, d.start_time, d.end_time
FROM   cron.job_run_details d
JOIN   cron.job j ON j.jobid = d.jobid
WHERE  j.jobname = 'monthly_payroll'
ORDER  BY d.start_time DESC;
