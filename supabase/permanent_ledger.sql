-- ==============================================================================
-- 1. PERMANENT SCHEMA EXPANSION
-- ==============================================================================

-- Table: daily_focus_summaries
-- Permanent ledger for longitudinal time-series classification
CREATE TABLE IF NOT EXISTS daily_focus_summaries (
    id SERIAL PRIMARY KEY,
    calendar_date DATE UNIQUE NOT NULL,
    total_minutes_logged INT DEFAULT 0,
    overall_average_focus INT DEFAULT 0,
    physics_minutes INT DEFAULT 0,
    chemistry_minutes INT DEFAULT 0,
    maths_minutes INT DEFAULT 0,
    total_distraction_events INT DEFAULT 0,
    micro_sleep_count INT DEFAULT 0
);

-- ==============================================================================
-- PERMANENT DATA RETENTION ROW-LEVEL SECURITY (RLS)
-- ==============================================================================

ALTER TABLE daily_focus_summaries ENABLE ROW LEVEL SECURITY;

-- Explicitly allow frontend reads (SELECT)
CREATE POLICY select_daily_focus_summaries 
ON daily_focus_summaries 
FOR SELECT 
TO authenticated, anon 
USING (true);

-- Explicitly allow frontend inserts (INSERT)
CREATE POLICY insert_daily_focus_summaries 
ON daily_focus_summaries 
FOR INSERT 
TO authenticated, anon 
WITH CHECK (true);

-- Strictly block all frontend modifications (UPDATE) to prevent historical tampering
CREATE POLICY deny_update_daily_focus_summaries 
ON daily_focus_summaries 
FOR UPDATE 
TO authenticated, anon 
USING (false) 
WITH CHECK (false);

-- Strictly block all frontend deletions (DELETE) to guarantee permanent retention
CREATE POLICY deny_delete_daily_focus_summaries 
ON daily_focus_summaries 
FOR DELETE 
TO authenticated, anon 
USING (false);


-- ==============================================================================
-- 2. AUTOMATED DAILY ROLLUP FUNCTION
-- ==============================================================================

-- Designed to be run daily via pg_cron or triggered on-demand.
-- SECURITY DEFINER allows the function to bypass the strict RLS UPDATE block 
-- so the database engine can legally run the UPSERT aggregation.
CREATE OR REPLACE FUNCTION execute_daily_rollup(target_date DATE DEFAULT CURRENT_DATE)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_total_minutes INT := 0;
    v_avg_focus INT := 0;
    v_physics_mins INT := 0;
    v_chemistry_mins INT := 0;
    v_maths_mins INT := 0;
    v_distractions INT := 0;
    v_micro_sleeps INT := 0;
BEGIN
    -- Aggregate exact minutes directly from the high-frequency telemetry_logs layer
    -- (Assuming 1 record = 1 second of active polling based on the pipeline math)
    SELECT 
        COALESCE((COUNT(*) / 60), 0) AS total_minutes,
        COALESCE(AVG(t.focus_score), 0) AS avg_score,
        COALESCE((SUM(CASE WHEN s.subject_tag ILIKE '%physics%' THEN 1 ELSE 0 END) / 60), 0),
        COALESCE((SUM(CASE WHEN s.subject_tag ILIKE '%chemistry%' THEN 1 ELSE 0 END) / 60), 0),
        COALESCE((SUM(CASE WHEN s.subject_tag ILIKE '%math%' THEN 1 ELSE 0 END) / 60), 0),
        COALESCE(SUM(CASE WHEN t.predicted_state = 'Digital Distraction' OR t.predicted_state = 'Drifting' THEN 1 ELSE 0 END), 0),
        COALESCE(SUM(CASE WHEN t.predicted_state = 'Micro-sleep Detected' OR t.predicted_state = 'Cognitive Fatigue' THEN 1 ELSE 0 END), 0)
    INTO 
        v_total_minutes,
        v_avg_focus,
        v_physics_mins,
        v_chemistry_mins,
        v_maths_mins,
        v_distractions,
        v_micro_sleeps
    FROM telemetry_logs t
    JOIN focus_sessions s ON t.session_id = s.id
    WHERE DATE(t.timestamp AT TIME ZONE 'UTC') = target_date;

    -- Upsert the consolidated day's metrics into the permanent ledger
    INSERT INTO daily_focus_summaries (
        calendar_date, 
        total_minutes_logged, 
        overall_average_focus, 
        physics_minutes, 
        chemistry_minutes, 
        maths_minutes, 
        total_distraction_events, 
        micro_sleep_count
    ) VALUES (
        target_date, 
        v_total_minutes, 
        v_avg_focus, 
        v_physics_mins, 
        v_chemistry_mins, 
        v_maths_mins, 
        v_distractions, 
        v_micro_sleeps
    )
    ON CONFLICT (calendar_date) DO UPDATE SET
        total_minutes_logged = EXCLUDED.total_minutes_logged,
        overall_average_focus = EXCLUDED.overall_average_focus,
        physics_minutes = EXCLUDED.physics_minutes,
        chemistry_minutes = EXCLUDED.chemistry_minutes,
        maths_minutes = EXCLUDED.maths_minutes,
        total_distraction_events = EXCLUDED.total_distraction_events,
        micro_sleep_count = EXCLUDED.micro_sleep_count;
END;
$$;
