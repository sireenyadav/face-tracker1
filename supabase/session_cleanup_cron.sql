-- 1. Add the column to track the last telemetry timestamp
ALTER TABLE focus_sessions
ADD COLUMN IF NOT EXISTS last_telemetry_at TIMESTAMPTZ DEFAULT NOW();

-- 2. Create an index to make the cron query fast
CREATE INDEX IF NOT EXISTS idx_focus_sessions_active_cleanup 
ON focus_sessions (status, last_telemetry_at);

-- 3. Enable the pg_cron extension if not already enabled (Requires Supabase superuser, usually enabled by default)
CREATE EXTENSION IF NOT EXISTS pg_cron;

-- 4. Schedule the cron job to run every 1 minute
-- This automatically marks any 'active' session as 'completed' if no telemetry has been received for over 60 seconds.
SELECT cron.schedule(
  'cleanup-stale-sessions', 
  '* * * * *', 
  $$
  UPDATE focus_sessions 
  SET status = 'completed' 
  WHERE status = 'active' 
  AND last_telemetry_at < NOW() - INTERVAL '2 minutes';
  $$
);

-- Note: If you ever need to unschedule it, you can run:
-- SELECT cron.unschedule('cleanup-stale-sessions');

-- 5. Enable replication for the focus_sessions table
ALTER TABLE focus_sessions REPLICA IDENTITY FULL;

-- 6. Add the table to the supabase_realtime publication
ALTER PUBLICATION supabase_realtime ADD TABLE focus_sessions;
