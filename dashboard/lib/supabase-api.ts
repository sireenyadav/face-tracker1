// dashboard/lib/supabase-api.ts
import { createClient } from '@supabase/supabase-js';

// Initialize Supabase Client
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL!;
const supabaseKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!;

export const supabase = createClient(supabaseUrl, supabaseKey);

// ==============================================================================
// TYPE DEFINITIONS
// ==============================================================================

export interface SessionAnalytics {
  session_id: string;
  subject_tag: string;
  target_exam: string;
  session_start: string;
  session_end: string;
  total_duration_minutes: number;
  average_focus_score: number;
  time_in_hyper_focus_pct: number;
  fatigue_index: number;
  app_compliance_ratio: number;
}

export interface FocusDecayBucket {
  bucket_start: string;
  bucket_end: string;
  minute_bucket: number;
  average_score: number;
  dominant_state: string;
}

export interface RawTelemetryLog {
  timestamp: string;
  focus_score: number;
  predicted_state: string;
}

// ==============================================================================
// FETCH FUNCTIONS FOR NEXT.JS COMPONENTS
// ==============================================================================

/**
 * Fetches the deep session analytics view for all sessions.
 * Returns core KPIs like average_focus_score, fatigue_index, and app_compliance_ratio.
 */
export async function fetchSessionAnalytics(): Promise<SessionAnalytics[]> {
  const { data, error } = await supabase
    .from('session_analytics_view')
    .select('*')
    .order('session_start', { ascending: false });

  if (error) {
    console.error('Error fetching session analytics:', error);
    throw error;
  }

  return data as SessionAnalytics[];
}

/**
 * Calls the Advanced Focus-Decay RPC Function for a specific session.
 * Used to map the 15-minute mental stamina bucket drops over long study sessions.
 */
export async function fetchAttentionDecay(sessionId: string): Promise<FocusDecayBucket[]> {
  const { data, error } = await supabase.rpc('calculate_attention_decay', {
    p_session_id: sessionId
  });

  if (error) {
    console.error('Error fetching attention decay RPC:', error);
    throw error;
  }

  return data as FocusDecayBucket[];
}

/**
 * Fetches the exact high-frequency telemetry logs for a given session.
 * Ideal for mapping into the Recharts AreaChart component for a smooth graphical timeline.
 */
export async function fetchTelemetryTimeline(sessionId: string): Promise<RawTelemetryLog[]> {
  const { data, error } = await supabase
    .from('telemetry_logs')
    .select('timestamp, focus_score, predicted_state')
    .eq('session_id', sessionId)
    .order('timestamp', { ascending: true });

  if (error) {
    console.error('Error fetching telemetry timeline:', error);
    throw error;
  }

  return data as RawTelemetryLog[];
}
