-- supabase/webrtc_signaling.sql

-- Creates the time-series table for P2P SDP and ICE Candidate exchanges
CREATE TABLE IF NOT EXISTS webrtc_signaling (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id UUID NOT NULL REFERENCES focus_sessions(id) ON DELETE CASCADE,
    type TEXT NOT NULL, -- e.g., 'offer_parent', 'answer_tablet', 'candidate_tablet', 'candidate_parent'
    payload JSONB NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Ensure Realtime is enabled for signaling pushes
ALTER PUBLICATION supabase_realtime ADD TABLE webrtc_signaling;
