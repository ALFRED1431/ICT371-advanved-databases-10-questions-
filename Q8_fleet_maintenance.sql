-- =====================================================================
-- ICT371 Advanced Database
-- QUESTION 8: Transport Fleet Maintenance (50 marks)
-- DBMS: PostgreSQL 14+ (PL/pgSQL; pg_cron for scheduled jobs)
-- Service due when current_odometer - last_service_odometer >= 5000 km.
-- =====================================================================

DROP TABLE IF EXISTS service_alerts, trips, vehicles CASCADE;

-- ---------------------------------------------------------------------
-- Q8 (a) Database and seed data [6 marks]
-- ---------------------------------------------------------------------
CREATE TABLE vehicles (
    vehicle_id             SERIAL PRIMARY KEY,
    registration           VARCHAR(20) NOT NULL UNIQUE,
    current_odometer       INTEGER     NOT NULL CHECK (current_odometer >= 0),
    last_service_odometer  INTEGER     NOT NULL CHECK (last_service_odometer >= 0),
    CONSTRAINT ck_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
    trip_id        SERIAL PRIMARY KEY,
    vehicle_id     INTEGER NOT NULL REFERENCES vehicles(vehicle_id),
    trip_on        DATE    NOT NULL,
    start_odometer INTEGER NOT NULL CHECK (start_odometer >= 0),
    end_odometer   INTEGER NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
    vehicle_id       INTEGER PRIMARY KEY REFERENCES vehicles(vehicle_id),
    km_since_service INTEGER NOT NULL,
    flagged_on       DATE    NOT NULL
);

-- Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
    ('ABC 1001', 12000, 10000),    -- will be 3000 km since service  (not due)
    ('ABC 2002', 20000, 14000),    -- will be 6900 km since service  (due)
    ('ABC 3003',  3000,     0);    -- will be exactly 5000 km        (due, boundary)

-- ---------------------------------------------------------------------
-- Q8 (b) Function fn_service_due [6 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_current INTEGER;
    v_last    INTEGER;
BEGIN
    SELECT current_odometer, last_service_odometer
      INTO v_current, v_last
      FROM vehicles
     WHERE vehicle_id = p_vehicle_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;

    RETURN (v_current - v_last) >= 5000;
END;
$$;

-- ---------------------------------------------------------------------
-- Q8 (c) Procedure pr_record_trip [8 marks]
-- Only inserts the trip. The odometer is NOT updated here - the trigger
-- in (d) does it.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_record_trip(
    p_vehicle_id INTEGER,
    p_trip_on    DATE,
    p_start      INTEGER,
    p_end        INTEGER)
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', p_vehicle_id;
    END IF;
    IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
        RAISE EXCEPTION 'Trip date and odometer values must not be NULL';
    END IF;
    IF p_end <= p_start THEN
        RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
    END IF;

    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$;

-- ---------------------------------------------------------------------
-- Q8 (d) Trigger on trips [8 marks]
-- BEFORE INSERT row trigger: verifies start = vehicle's current odometer,
-- rejects invalid mileage, then moves current_odometer to the trip end
-- exactly once (one UPDATE per inserted row).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_current INTEGER;
BEGIN
    SELECT current_odometer INTO v_current
    FROM vehicles
    WHERE vehicle_id = NEW.vehicle_id
    FOR UPDATE;                                  -- serialise trips per vehicle

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown vehicle_id: %', NEW.vehicle_id;
    END IF;
    IF NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
        RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
    END IF;
    IF NEW.start_odometer <> v_current THEN
        RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
                        NEW.start_odometer, v_current;
    END IF;

    UPDATE vehicles
       SET current_odometer = NEW.end_odometer
     WHERE vehicle_id = NEW.vehicle_id;

    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- ---------------------------------------------------------------------
-- Q8 (a) continued: six trips added THROUGH the procedure (trigger active)
-- ---------------------------------------------------------------------
CALL pr_record_trip(1, CURRENT_DATE - 10, 12000, 12400);
CALL pr_record_trip(1, CURRENT_DATE - 5,  12400, 13000);
CALL pr_record_trip(2, CURRENT_DATE - 9,  20000, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 4,  20300, 20900);
CALL pr_record_trip(3, CURRENT_DATE - 8,   3000,  3500);
CALL pr_record_trip(3, CURRENT_DATE - 3,   3500,  5000);

SELECT * FROM trips ORDER BY trip_id;
SELECT vehicle_id, registration, current_odometer, last_service_odometer FROM vehicles ORDER BY 1;

-- Tests
SELECT vehicle_id, fn_service_due(vehicle_id) AS due FROM vehicles ORDER BY 1; -- f, t, t
DO $$ BEGIN PERFORM fn_service_due(999);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 13000, 13000);   -- end not > start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(1, CURRENT_DATE, 9999, 10500);    -- wrong start
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_record_trip(99, CURRENT_DATE, 0, 10);         -- unknown vehicle
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;
DO $$ BEGIN
    INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
    VALUES (1, CURRENT_DATE, 13000, 12000);                       -- direct SQL, invalid mileage
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected: %', SQLERRM; END $$;

-- ---------------------------------------------------------------------
-- Q8 (e) View v_service_due [5 marks]
-- ---------------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM   vehicles
WHERE  current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due ORDER BY registration;     -- ABC 2002 and ABC 3003

-- ---------------------------------------------------------------------
-- Q8 (f) Index [5 marks]
-- Composite (vehicle_id, trip_on): equality on the vehicle, then a range
-- on trip_on, so one vehicle's trips for a period are read contiguously
-- and already ordered by date.
-- ---------------------------------------------------------------------
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
ANALYZE trips;

SET enable_seqscan = OFF;    -- demo table is tiny
EXPLAIN
SELECT trip_id, trip_on, start_odometer, end_odometer
FROM   trips
WHERE  vehicle_id = 2
  AND  trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE
ORDER  BY trip_on;
RESET enable_seqscan;

-- ---------------------------------------------------------------------
-- Q8 (g) Scheduled job [6 marks]
-- 1) remove alerts for vehicles no longer due, 2) insert/update alerts
--    for vehicles that are due.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql
AS $$
BEGIN
    DELETE FROM service_alerts sa
    WHERE NOT EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.vehicle_id = sa.vehicle_id
          AND v.current_odometer - v.last_service_odometer >= 5000);

    INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
    SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
    FROM   vehicles
    WHERE  current_odometer - last_service_odometer >= 5000
    ON CONFLICT (vehicle_id) DO UPDATE
        SET km_since_service = EXCLUDED.km_since_service,
            flagged_on       = EXCLUDED.flagged_on;
END;
$$;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();                  -- rerun: still one row per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;  -- vehicles 2 and 3

-- Servicing vehicle 2 removes its alert on the next run
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 2;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;  -- only vehicle 3 remains

-- Every Monday at 06:00 (pg_cron uses UTC unless cron.timezone is configured)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
                     $$CALL pr_refresh_service_alerts()$$);
