-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 5: Hostel Room Allocation (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- =====================================================================

DROP TABLE IF EXISTS occupancy_snapshot, allocations, rooms, students CASCADE;

-- ---------------------------------------------------------------------
-- Q5 (a) Database and seed data [6 marks]  -- tables
-- ---------------------------------------------------------------------
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(20)  NOT NULL UNIQUE,
    full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
    room_id     SERIAL PRIMARY KEY,
    room_number VARCHAR(10) NOT NULL UNIQUE,
    capacity    INTEGER     NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
    allocation_id SERIAL PRIMARY KEY,
    student_id    INTEGER     NOT NULL REFERENCES students(student_id),
    room_id       INTEGER     NOT NULL REFERENCES rooms(room_id),
    allocated_on  DATE        NOT NULL,
    released_on   DATE        NULL,
    status        VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    CONSTRAINT ck_alloc_status CHECK (status IN ('ACTIVE', 'ENDED')),
    CONSTRAINT ck_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL) OR
        (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on))
);

-- Extra safeguard under concurrency: one ACTIVE allocation per student
CREATE UNIQUE INDEX uq_one_active_per_student
    ON allocations (student_id) WHERE status = 'ACTIVE';

CREATE TABLE occupancy_snapshot (
    snapshot_date DATE    NOT NULL,
    room_id       INTEGER NOT NULL REFERENCES rooms(room_id),
    occupied_beds INTEGER NOT NULL,
    free_beds     INTEGER NOT NULL,
    PRIMARY KEY (snapshot_date, room_id)
);

INSERT INTO students (student_number, full_name) VALUES
    ('202400001', 'Mwansa Banda'),
    ('202400002', 'Temwa Phiri'),
    ('202400003', 'Chanda Mulenga'),
    ('202400004', 'Natasha Zulu'),
    ('202400005', 'Joseph Tembo');

INSERT INTO rooms (room_number, capacity) VALUES
    ('R101', 2),     -- will be FULL
    ('R102', 3),     -- partly occupied
    ('R103', 2);     -- empty

-- ---------------------------------------------------------------------
-- Q5 (b) Function fn_free_beds [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_capacity INTEGER;
    v_active   INTEGER;
BEGIN
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    SELECT COUNT(*) INTO v_active
    FROM allocations
    WHERE room_id = p_room_id AND status = 'ACTIVE';    -- ENDED rows ignored

    RETURN v_capacity - v_active;
END;
$$;

-- ---------------------------------------------------------------------
-- Q5 (c) Procedure pr_allocate_room [8 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_allocate_room(
    p_student_id   INTEGER,
    p_room_id      INTEGER,
    p_allocated_on DATE)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_allocated_on IS NULL THEN
        RAISE EXCEPTION 'Allocation date must not be NULL';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    -- lock the room row: concurrent allocations to the same room queue up
    PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown room_id: %', p_room_id;
    END IF;

    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
        RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
    END IF;

    IF fn_free_beds(p_room_id) <= 0 THEN
        RAISE EXCEPTION 'Room % is full', p_room_id;
    END IF;

    INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
    VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END;
$$;

-- ---------------------------------------------------------------------
-- Q5 (d) Trigger [8 marks]
-- BEFORE INSERT OR UPDATE: enforces capacity and one ACTIVE allocation per
-- student for DIRECT SQL changes. The row being updated is excluded when
-- counting "other" allocations.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_allocation_rules()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_capacity INTEGER;
    v_others   INTEGER;
BEGIN
    IF NEW.status = 'ACTIVE' THEN
        -- one ACTIVE allocation per student
        IF EXISTS (SELECT 1 FROM allocations a
                   WHERE a.student_id = NEW.student_id
                     AND a.status = 'ACTIVE'
                     AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id)) THEN
            RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
        END IF;

        -- capacity (lock the room row so concurrent changes are serialised)
        SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Unknown room_id: %', NEW.room_id;
        END IF;

        SELECT COUNT(*) INTO v_others
        FROM allocations a
        WHERE a.room_id = NEW.room_id
          AND a.status = 'ACTIVE'
          AND (TG_OP = 'INSERT' OR a.allocation_id <> NEW.allocation_id);

        IF v_others >= v_capacity THEN
            RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_fn_allocation_rules();

-- ---------------------------------------------------------------------
-- Q5 (a) continued: allocations (full, partly occupied and empty rooms)
-- ---------------------------------------------------------------------
CALL pr_allocate_room(1, 1, '2026-09-01');   -- R101: 2/2 -> full
CALL pr_allocate_room(2, 1, '2026-09-01');
CALL pr_allocate_room(3, 2, '2026-09-02');   -- R102: 1/3 -> partly occupied
-- R103 stays empty. ENDED allocations = history (do not occupy beds):
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
    (4, 1, '2026-02-01', '2026-06-30', 'ENDED'),
    (5, 3, '2026-02-01', '2026-06-30', 'ENDED');

SELECT * FROM allocations ORDER BY allocation_id;
SELECT room_id, fn_free_beds(room_id) AS free_beds FROM rooms ORDER BY room_id;  -- 0, 2, 2

-- Rejection tests (procedure and direct SQL)
DO $$ BEGIN CALL pr_allocate_room(4, 1, CURRENT_DATE);                -- room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 3, CURRENT_DATE);                -- already ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(99, 3, CURRENT_DATE);               -- unknown student
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(4, 99, CURRENT_DATE);               -- unknown room
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status)
    VALUES (4, 1, CURRENT_DATE, 'ACTIVE');                            -- direct SQL, room full
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN
    INSERT INTO allocations (student_id, room_id, allocated_on, status)
    VALUES (1, 3, CURRENT_DATE, 'ACTIVE');                            -- direct SQL, 2nd ACTIVE
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_allocate_room(1, 999, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN PERFORM fn_free_beds(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- UPDATE of an existing ACTIVE row to itself passes (row excluded from count)
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- ---------------------------------------------------------------------
-- Q5 (e) View v_room_occupancy [5 marks]
-- LEFT JOIN with the ACTIVE condition in ON keeps rooms with no allocations.
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)::INTEGER              AS occupied_beds,
       (r.capacity - COUNT(a.allocation_id))::INTEGER AS free_beds
FROM   rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

SELECT * FROM v_room_occupancy ORDER BY room_number;

-- ---------------------------------------------------------------------
-- Q5 (f) Index [5 marks]
-- Partial index on room_id for ACTIVE rows only: occupancy counts and
-- capacity checks only ever look at ACTIVE rows, so the index stays small
-- (ended history is excluded) and fast.
-- ---------------------------------------------------------------------
CREATE INDEX idx_alloc_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
ANALYZE allocations;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT allocation_id, student_id
FROM   allocations
WHERE  room_id = 1
  AND  status = 'ACTIVE';
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q5 (g) Scheduled job [6 marks]
-- One row per (date, room); rerun replaces values.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
    SELECT CURRENT_DATE,
           r.room_id,
           COUNT(a.allocation_id)::INTEGER,
           (r.capacity - COUNT(a.allocation_id))::INTEGER
    FROM   rooms r
    LEFT JOIN allocations a
           ON a.room_id = r.room_id AND a.status = 'ACTIVE'
    GROUP BY r.room_id, r.capacity
    ON CONFLICT (snapshot_date, room_id) DO UPDATE
        SET occupied_beds = EXCLUDED.occupied_beds,
            free_beds     = EXCLUDED.free_beds;
END;
$$;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();      -- rerun: replaced, 3 rows only
SELECT * FROM occupancy_snapshot ORDER BY room_id;

-- Daily at 23:55 (pg_cron uses UTC unless cron.timezone is configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_occupancy_daily', '55 23 * * *',
                     $$CALL pr_refresh_occupancy()$$);
