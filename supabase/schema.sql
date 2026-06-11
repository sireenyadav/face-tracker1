-- ==============================================================================
-- 1. DATABASE SCHEMA
-- ==============================================================================

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Table: focus_sessions
-- Represents a continuous block of studying
CREATE TABLE IF NOT EXISTS focus_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL DEFAULT '00000000-0000-0000-0000-000000000000'::UUID,
    subject_tag TEXT,
    target_exam TEXT,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    ended_at TIMESTAMPTZ,
    status TEXT DEFAULT 'active'
);

-- Table: telemetry_logs
-- Stores the high-frequency batched outputs from the Android probabilistic fusion engine
CREATE TABLE IF NOT EXISTS telemetry_logs (
    id BIGSERIAL PRIMARY KEY,
    session_id UUID NOT NULL REFERENCES focus_sessions(id) ON DELETE CASCADE,
    timestamp TIMESTAMPTZ NOT NULL,
    focus_score INT NOT NULL,
    predicted_state TEXT NOT NULL,
    active_package TEXT NOT NULL,
    yaw FLOAT NOT NULL,
    pitch FLOAT NOT NULL,
    blink_rate_ema FLOAT NOT NULL
);

-- Highly optimized indexes for time-series range scans and session aggregation
CREATE INDEX IF NOT EXISTS idx_telemetry_session_id ON telemetry_logs(session_id);
CREATE INDEX IF NOT EXISTS idx_telemetry_timestamp ON telemetry_logs(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_telemetry_session_timestamp ON telemetry_logs(session_id, timestamp);


-- ==============================================================================
-- 2. DEEP SESSION ANALYTICS VIEW
-- ==============================================================================

-- Calculates mathematical mean, hyper-focus percentage, app compliance, and fatigue
CREATE OR REPLACE VIEW session_analytics_view AS
WITH session_durations AS (
    SELECT 
        session_id,
        MIN(timestamp) AS session_start,
        MAX(timestamp) AS session_end,
        EXTRACT(EPOCH FROM (MAX(timestamp) - MIN(timestamp))) / 60.0 AS total_duration_minutes,
        COUNT(*) AS total_frames
    FROM telemetry_logs
    GROUP BY session_id
),
hyper_focus_stats AS (
    SELECT 
        session_id,
        COUNT(*) AS hyper_focus_frames
    FROM telemetry_logs
    WHERE predicted_state = 'Hyper-Focus'
    GROUP BY session_id
),
educational_app_stats AS (
    SELECT 
        session_id,
        COUNT(*) AS educational_frames
    FROM telemetry_logs
    WHERE active_package IN (
        'com.facetracker.face_tracker', 
        'com.quizlet.quizletandroid', 
        'com.google.android.apps.docs', 
        'com.duolingo',
        'com.khanacademy.android'
    )
    GROUP BY session_id
),
fatigue_metrics AS (
    SELECT 
        session_id,
        -- Fatigue Index mapping: We calculate the acceleration (slope) of blink_rate_ema over time.
        -- Linear regression slope formula: Covariance(x, y) / Variance(x)
        -- Scaled up by 3600 to represent the estimated change in the EMA per hour.
        COALESCE(
            COVAR_POP(EXTRACT(EPOCH FROM timestamp), blink_rate_ema) / 
            NULLIF(VAR_POP(EXTRACT(EPOCH FROM timestamp)), 0), 
        0) * 3600 AS fatigue_index
    FROM telemetry_logs
    GROUP BY session_id
)
SELECT 
    f.id AS session_id,
    f.subject_tag,
    f.target_exam,
    sd.session_start,
    sd.session_end,
    sd.total_duration_minutes,
    COALESCE(AVG(t.focus_score), 0) AS average_focus_score,
    COALESCE((hf.hyper_focus_frames::FLOAT / NULLIF(sd.total_frames, 0)) * 100.0, 0) AS time_in_hyper_focus_pct,
    fm.fatigue_index,
    COALESCE((ea.educational_frames::FLOAT / NULLIF(sd.total_frames, 0)), 0) AS app_compliance_ratio
FROM focus_sessions f
LEFT JOIN telemetry_logs t ON f.id = t.session_id
LEFT JOIN session_durations sd ON f.id = sd.session_id
LEFT JOIN hyper_focus_stats hf ON f.id = hf.session_id
LEFT JOIN educational_app_stats ea ON f.id = ea.session_id
LEFT JOIN fatigue_metrics fm ON f.id = fm.session_id
GROUP BY 
    f.id, f.subject_tag, f.target_exam, sd.session_start, sd.session_end, 
    sd.total_duration_minutes, hf.hyper_focus_frames, sd.total_frames, 
    fm.fatigue_index, ea.educational_frames;


-- ==============================================================================
-- 3. ADVANCED FOCUS-DECAY RPC FUNCTION
-- ==============================================================================

-- Chunks a study session into 15-minute chronological buckets to map the mental stamina curve
CREATE OR REPLACE FUNCTION calculate_attention_decay(p_session_id UUID)
RETURNS TABLE (
    bucket_start TIMESTAMPTZ,
    bucket_end TIMESTAMPTZ,
    minute_bucket INT,
    average_score FLOAT,
    dominant_state TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    WITH session_start AS (
        SELECT MIN(timestamp) AS start_time 
        FROM telemetry_logs 
        WHERE session_id = p_session_id
    ),
    binned_logs AS (
        SELECT 
            t.session_id,
            t.timestamp,
            t.focus_score,
            t.predicted_state,
            -- Bucket algorithm: Group by 15-minute intervals (900 seconds)
            FLOOR(EXTRACT(EPOCH FROM (t.timestamp - s.start_time)) / 900)::INT AS minute_bucket_index,
            s.start_time + (FLOOR(EXTRACT(EPOCH FROM (t.timestamp - s.start_time)) / 900)::INT * INTERVAL '15 minutes') AS bucket_timestamp
        FROM telemetry_logs t
        CROSS JOIN session_start s
        WHERE t.session_id = p_session_id
    ),
    bucket_aggregates AS (
        SELECT 
            b.minute_bucket_index,
            b.bucket_timestamp,
            b.bucket_timestamp + INTERVAL '15 minutes' AS interval_end,
            AVG(b.focus_score) AS avg_focus,
            MODE() WITHIN GROUP (ORDER BY b.predicted_state) AS dom_state
        FROM binned_logs b
        GROUP BY b.minute_bucket_index, b.bucket_timestamp
        ORDER BY b.minute_bucket_index ASC
    )
    SELECT 
        ba.bucket_timestamp AS bucket_start,
        ba.interval_end AS bucket_end,
        ba.minute_bucket_index * 15 AS minute_bucket, -- Absolute minute index (0, 15, 30...)
        ba.avg_focus AS average_score,
        ba.dom_state AS dominant_state
    FROM bucket_aggregates ba;
END;
$$;


-- ==============================================================================
-- 4. BULK INSERT TELEMETRY (COMPANION PIPELINE)
-- ==============================================================================

-- Handles the batched POST requests sent from the Native Kotlin Coroutine
CREATE OR REPLACE FUNCTION bulk_insert_telemetry(p_telemetry_data JSONB)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    log_record JSONB;
    v_session_id UUID;
    v_subject_tag TEXT;
    v_target_exam TEXT;
BEGIN
    -- Unnest the batched JSON Array and insert dynamically
    FOR log_record IN SELECT * FROM jsonb_array_elements(p_telemetry_data)
    LOOP
        -- Assume a default session generation logic if UUID is not provided by Android
        v_session_id := COALESCE((log_record->>'session_id')::UUID, '11111111-1111-1111-1111-111111111111'::UUID);
        v_subject_tag := log_record->>'subject_tag';
        v_target_exam := log_record->>'target_exam';

        -- Ensure parent session exists
        INSERT INTO focus_sessions (id, subject_tag, target_exam)
        VALUES (v_session_id, v_subject_tag, v_target_exam)
        ON CONFLICT (id) DO NOTHING;

        -- Insert the raw probability fusion metrics
        INSERT INTO telemetry_logs (
            session_id, 
            timestamp, 
            focus_score, 
            predicted_state, 
            active_package, 
            yaw, 
            pitch, 
            blink_rate_ema
        ) VALUES (
            v_session_id,
            (log_record->>'timestamp')::TIMESTAMPTZ,
            (log_record->>'focus_score')::INT,
            log_record->>'predicted_state',
            COALESCE(log_record->>'active_package', 'com.facetracker.face_tracker'),
            COALESCE((log_record->>'w_yaw')::FLOAT, 1.0),
            COALESCE((log_record->>'w_pitch')::FLOAT, 1.0),
            COALESCE((log_record->>'w_eyes')::FLOAT, 1.0)
        );
    END LOOP;
END;
$$;
