-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 4: Clinic Appointment Scheduling (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- Slots: 09:00, 10:00, 11:00, 12:00. No two non-cancelled appointments
-- may share doctor + date + slot.
-- =====================================================================

DROP TABLE IF EXISTS clinic_summary, appointments, doctors, patients CASCADE;

-- ---------------------------------------------------------------------
-- Q4 (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INTEGER     NOT NULL REFERENCES patients(patient_id),
    doctor_id       INTEGER     NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE        NOT NULL,
    slot_time       TIME        NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_slot   CHECK (slot_time IN ('09:00', '10:00', '11:00', '12:00')),
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);

-- Extra race-condition safeguard: the trigger in (d) gives a friendly
-- message; this partial unique index guarantees the rule under concurrency.
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INTEGER NOT NULL DEFAULT 0,
    attended_count  INTEGER NOT NULL DEFAULT 0,
    cancelled_count INTEGER NOT NULL DEFAULT 0
);

INSERT INTO patients (full_name) VALUES
    ('Mwansa Banda'), ('Temwa Phiri'), ('Chanda Mulenga');

INSERT INTO doctors (full_name) VALUES
    ('Dr. Kabwe'), ('Dr. Mumba'), ('Dr. Sakala');

-- ---------------------------------------------------------------------
-- Q4 (b) Function fn_daily_load [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INTEGER, p_day DATE)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_count INTEGER;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;

    SELECT COUNT(*) INTO v_count
    FROM appointments
    WHERE doctor_id = p_doctor_id
      AND appointment_day = p_day
      AND status <> 'CANCELLED';

    RETURN v_count;        -- COUNT(*) is 0 when the day has no bookings
END;
$$;

-- ---------------------------------------------------------------------
-- Q4 (c) Procedure pr_book_appointment [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(
    p_patient_id INTEGER,
    p_doctor_id  INTEGER,
    p_day        DATE,
    p_slot       TIME)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient_id: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor_id: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or NULL', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN ('09:00', '10:00', '11:00', '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- the clash check is performed by trigger trg_appointment_clash
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- ---------------------------------------------------------------------
-- Q4 (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE row trigger. On UPDATE the row being changed is
-- excluded from the clash search. Cancelled rows never clash.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_appointment_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
            FROM   appointments a
            WHERE  a.doctor_id       = NEW.doctor_id
              AND  a.appointment_day = NEW.appointment_day
              AND  a.slot_time       = NEW.slot_time
              AND  a.status         <> 'CANCELLED'
              AND  (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_appointment_clash();

-- ---------------------------------------------------------------------
-- Q4 (a) continued: six appointments (trigger is already active)
-- Appointment 6 shares a slot with appointment 1 but is CANCELLED, so
-- it does not violate the rule.
-- ---------------------------------------------------------------------
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
    (1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
    (2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
    (3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
    (1, 2, CURRENT_DATE - 1, '11:00', 'ATTENDED'),
    (2, 3, CURRENT_DATE + 1, '12:00', 'BOOKED'),
    (3, 1, CURRENT_DATE,     '09:00', 'CANCELLED');

SELECT * FROM appointments ORDER BY appointment_id;

-- Tests
CALL pr_book_appointment(3, 3, CURRENT_DATE + 2, '10:00');     -- valid
SELECT fn_daily_load(1, CURRENT_DATE)     AS doctor1_today;     -- 2
SELECT fn_daily_load(3, CURRENT_DATE + 30) AS empty_day;        -- 0

DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');      -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');  -- past date
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');  -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '09:00'); -- unknown patient
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);                    -- unknown doctor
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- UPDATE test: moving appointment 1 into its own slot is fine (self excluded);
-- moving appointment 2 onto appointment 1's slot is rejected.
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 1;
DO $$ BEGIN UPDATE appointments SET slot_time = '09:00' WHERE appointment_id = 2;
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------
-- Q4 (e) View v_today_appointments [5 marks]
-- Exposes only patient name, doctor name and slot (no IDs / other data).
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM   appointments a
JOIN   patients p ON p.patient_id = a.patient_id
JOIN   doctors  d ON d.doctor_id  = a.doctor_id
WHERE  a.appointment_day = CURRENT_DATE
  AND  a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time, doctor_name;

-- ---------------------------------------------------------------------
-- Q4 (f) Index [5 marks]
-- Non-unique composite (appointment_day, doctor_id): supports "which
-- appointments does doctor X have on day Y" (and all doctors on a day).
-- ---------------------------------------------------------------------
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT appointment_id, patient_id, slot_time, status
FROM   appointments
WHERE  appointment_day = CURRENT_DATE
  AND  doctor_id = 1;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q4 (g) Scheduled job [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day must not be NULL';
    END IF;

    INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM   appointments
    WHERE  appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
        SET booked_count    = EXCLUDED.booked_count,
            attended_count  = EXCLUDED.attended_count,
            cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);   -- rerun replaces the row
SELECT * FROM clinic_summary;

-- Daily at 01:00 for the previous day (pg_cron uses UTC unless configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
                     $$CALL pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
