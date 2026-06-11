"use client";

/**
 * page.tsx — Parent Observer Dashboard
 *
 * JEE 2027 Focus Tracker — Parent Portal
 * Student: Sireen Yadav
 *
 * Bug fixes implemented:
 *  1. TWO separate useEffects for Supabase channel (mount-once) vs isVideoActive side-effects
 *  2. isVideoActiveRef kept in sync → no stale closure in realtime callback
 *  3. activeSessionIdRef for channel filter (session_id) that doesn't tear down on change
 *
 * Features:
 *  - Premium dark glassmorphism (navy/slate base, glowing cyan accents)
 *  - Observer Dashboard tab: FocusRingGauge, AreaChart, WebRTC video panel,
 *    live session timer, stats, recent sessions timeline using avg_focus_score
 *  - Notifications tab: focus drops < 60 from active session telemetry_logs
 *  - Framer Motion card entrance animations
 *  - Google Fonts: Inter + Playfair Display
 */

import React, {
  useState,
  useEffect,
  useRef,
  useCallback,
  useMemo,
} from "react";
import { createClient } from "@supabase/supabase-js";
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  ReferenceLine,
} from "recharts";
import { motion, AnimatePresence } from "framer-motion";
import {
  ShieldAlert,
  Video,
  BrainCircuit,
  ActivitySquare,
  LayoutDashboard,
  History,
  PowerOff,
  CheckCircle2,
  AlertCircle,
  Clock,
  BatteryMedium,
  Activity,
  Bell,
  Wifi,
  WifiOff,
  Zap,
  TrendingDown,
  ChevronRight,
  Eye,
} from "lucide-react";

import { FaceTrackerEdge } from "./components/FaceTrackerEdge";
import { GlassCard } from "./components/GlassCard";
import { FocusRingGauge } from "./components/FocusRingGauge";

// ---------------------------------------------------------------------------
// Supabase client
// ---------------------------------------------------------------------------
const SUPABASE_URL =
  process.env.NEXT_PUBLIC_SUPABASE_URL ||
  "https://crmjzxhlggfpisknbjrr.supabase.co";
const SUPABASE_KEY =
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY ||
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8";

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------
interface ChartPoint {
  timestamp: number;
  time: string;
  focus_score: number;
}

interface HistorySession {
  id: string;
  started_at: string | null;
  ended_at: string | null;
  status: string;
  subject_tag: string | null;
  chapter_name: string | null;
  lecture_number: number | null;
  avg_focus_score: number | null;
}

interface NotificationEvent {
  id: string;
  timestamp: string;
  focus_score: number;
  predicted_state: string;
}

type ActiveTab = "dashboard" | "notifications";

// ---------------------------------------------------------------------------
// Framer Motion variants
// ---------------------------------------------------------------------------
const cardVariants: any = {
  hidden: { opacity: 0, y: 24 },
  visible: (i: number) => ({
    opacity: 1,
    y: 0,
    transition: { duration: 0.45, delay: i * 0.07, ease: "easeOut" },
  }),
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
function formatDuration(ms: number): string {
  const totalSeconds = Math.floor(ms / 1000);
  const h = Math.floor(totalSeconds / 3600);
  const m = Math.floor((totalSeconds % 3600) / 60);
  const s = totalSeconds % 60;
  if (h > 0) return `${h}h ${m.toString().padStart(2, "0")}m`;
  return `${m.toString().padStart(2, "0")}:${s.toString().padStart(2, "0")}`;
}

function scoreColor(score: number): string {
  if (score >= 80) return "#10b981";
  if (score >= 50) return "#f59e0b";
  return "#ef4444";
}

function scoreBg(score: number): string {
  if (score >= 80) return "rgba(16,185,129,0.15)";
  if (score >= 50) return "rgba(245,158,11,0.15)";
  return "rgba(239,68,68,0.15)";
}

function stateToLabel(state: string): string {
  const map: Record<string, string> = {
    SCREEN_FOCUSED:       "Screen Focused",
    NEUTRAL_DRIFT:        "Neutral Drift",
    READING_OFFLINE:      "Reading Offline",
    PHONE_CHECK_SUSPECT:  "Phone Check?",
    DISTRACTED:           "Distracted",
  };
  return map[state] || state;
}

// ---------------------------------------------------------------------------
// Custom Recharts Tooltip
// ---------------------------------------------------------------------------
const CustomTooltip = ({ active, payload, label }: any) => {
  if (!active || !payload?.length) return null;
  const val: number = payload[0].value ?? 0;
  return (
    <div
      style={{
        background: "rgba(10,15,30,0.92)",
        border: "1px solid rgba(34,211,238,0.25)",
        borderRadius: 12,
        padding: "8px 14px",
        backdropFilter: "blur(8px)",
      }}
    >
      <p className="text-cyan-400 text-xs font-semibold mb-0.5">{label}</p>
      <p className="text-white font-bold text-lg leading-none">
        {val}
        <span className="text-cyan-400 text-sm font-medium ml-0.5">%</span>
      </p>
    </div>
  );
};

// ---------------------------------------------------------------------------
// Main Component
// ---------------------------------------------------------------------------
export default function ObserverDashboard() {
  // -- Live data state
  const [chartData, setChartData]             = useState<ChartPoint[]>([]);
  const [liveStatus, setLiveStatus]           = useState("Waiting for Telemetry…");
  const [currentScore, setCurrentScore]       = useState(0);
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null);

  // -- Session start time for elapsed timer
  const [sessionStartedAt, setSessionStartedAt] = useState<number | null>(null);
  const [elapsedDisplay, setElapsedDisplay]     = useState("00:00");

  // -- Video / WebRTC
  const [isVideoActive, setIsVideoActive]   = useState(false);
  const [webrtcStatus, setWebrtcStatus]     = useState("Video Feed Disconnected");

  // -- History + stats
  const [historySessions, setHistorySessions] = useState<HistorySession[]>([]);
  const [totalFocusTime, setTotalFocusTime]   = useState("00:00");
  const [avgConsistency, setAvgConsistency]   = useState(0);
  const [focusDrops, setFocusDrops]           = useState(0);

  // -- Notifications tab
  const [notifications, setNotifications] = useState<NotificationEvent[]>([]);
  const [unreadCount, setUnreadCount]      = useState(0);

  // -- Active tab
  const [activeTab, setActiveTab] = useState<ActiveTab>("dashboard");

  // -- Refs (Bug Fix #2, #3)
  const isVideoActiveRef    = useRef(false);
  const activeSessionIdRef  = useRef<string | null>(null);
  const videoRef            = useRef<HTMLVideoElement>(null);
  const peerConnectionRef   = useRef<RTCPeerConnection | null>(null);
  const elapsedIntervalRef  = useRef<ReturnType<typeof setInterval> | null>(null);

  // -- Sync refs with state (Bug Fix #2, #3)
  useEffect(() => { isVideoActiveRef.current = isVideoActive; }, [isVideoActive]);
  useEffect(() => { activeSessionIdRef.current = activeSessionId; }, [activeSessionId]);

  // ---------------------------------------------------------------------------
  // Elapsed timer — ticks every second when there's an active session
  // ---------------------------------------------------------------------------
  useEffect(() => {
    if (elapsedIntervalRef.current) {
      clearInterval(elapsedIntervalRef.current);
      elapsedIntervalRef.current = null;
    }

    if (sessionStartedAt) {
      const tick = () => {
        const elapsed = Date.now() - sessionStartedAt;
        setElapsedDisplay(formatDuration(elapsed));
      };
      tick();
      elapsedIntervalRef.current = setInterval(tick, 1000);
    } else {
      setElapsedDisplay("00:00");
    }

    return () => {
      if (elapsedIntervalRef.current) clearInterval(elapsedIntervalRef.current);
    };
  }, [sessionStartedAt]);

  // ---------------------------------------------------------------------------
  // Fetch initial data (sessions + stats)
  // ---------------------------------------------------------------------------
  const fetchInitialData = useCallback(async () => {
    // Mark parent as watching
    await supabase
      .from("device_status")
      .upsert({ device_id: "global", is_watching: true });

    // ── Active session ──────────────────────────────────────────────────────
    const { data: sessionData } = await supabase
      .from("focus_sessions")
      .select("*")
      .eq("status", "active")
      .order("started_at", { ascending: false })
      .limit(1);

    if (sessionData && sessionData.length > 0) {
      const session = sessionData[0];
      setActiveSessionId(session.id);
      activeSessionIdRef.current = session.id;
      setSessionStartedAt(
        session.started_at ? new Date(session.started_at).getTime() : null
      );

      const { data: logs } = await supabase
        .from("telemetry_logs")
        .select("*")
        .eq("session_id", session.id)
        .order("timestamp", { ascending: true });

      if (logs && logs.length > 0) {
        const formatted: ChartPoint[] = logs.map((log: any) => ({
          timestamp: new Date(log.timestamp).getTime(),
          time: new Date(log.timestamp).toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
          }),
          focus_score: log.focus_score,
        }));
        setChartData(formatted);
        setCurrentScore(logs[logs.length - 1].focus_score);
        setLiveStatus(stateToLabel(logs[logs.length - 1].predicted_state));

        // Populate notifications from initial logs
        const drops: NotificationEvent[] = logs
          .filter((l: any) => l.focus_score < 60)
          .map((l: any) => ({
            id: l.id ?? `${l.timestamp}`,
            timestamp: l.timestamp,
            focus_score: l.focus_score,
            predicted_state: l.predicted_state,
          }));
        setNotifications(drops.reverse());
        setUnreadCount(drops.length);
      } else {
        setLiveStatus("Waiting for Data…");
      }
    } else {
      setLiveStatus("Device Offline / Session Ended");
      setSessionStartedAt(null);
    }

    // ── Completed sessions history + stats ──────────────────────────────────
    const { data: historyData } = await supabase
      .from("focus_sessions")
      .select(
        "id, started_at, ended_at, status, subject_tag, chapter_name, lecture_number, avg_focus_score, telemetry_logs ( focus_score )"
      )
      .eq("status", "completed")
      .order("ended_at", { ascending: false });

    if (historyData && historyData.length > 0) {
      setHistorySessions(historyData.slice(0, 5));

      let totalMs = 0;
      let totalScoreSum = 0;
      let totalScoreCount = 0;
      let drops = 0;

      historyData.forEach((s: any) => {
        if (s.started_at && s.ended_at) {
          totalMs +=
            new Date(s.ended_at).getTime() - new Date(s.started_at).getTime();
        }

        // Prefer DB-level avg_focus_score; fall back to computing from logs
        if (s.avg_focus_score != null) {
          totalScoreSum += s.avg_focus_score;
          totalScoreCount++;
        } else if (s.telemetry_logs?.length > 0) {
          const sum = s.telemetry_logs.reduce(
            (a: number, l: any) => a + l.focus_score,
            0
          );
          totalScoreSum += sum / s.telemetry_logs.length;
          totalScoreCount++;
        }

        if (s.telemetry_logs) {
          drops += s.telemetry_logs.filter((l: any) => l.focus_score < 60).length;
        }
      });

      setTotalFocusTime(formatDuration(totalMs));
      setAvgConsistency(
        totalScoreCount > 0 ? Math.round(totalScoreSum / totalScoreCount) : 0
      );
      setFocusDrops(drops);
    }
  }, []);

  // ---------------------------------------------------------------------------
  // Bug Fix #1 — Supabase channel in a SEPARATE useEffect, runs ONCE on mount
  // ---------------------------------------------------------------------------
  useEffect(() => {
    fetchInitialData();

    const channel = supabase
      .channel("observer-dashboard-v2")
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "telemetry_logs" },
        (payload) => {
          const newLog = payload.new as any;

          // Bug Fix #3 — read session ID from ref, not closure
          if (newLog.session_id !== activeSessionIdRef.current) return;

          // Bug Fix #2 — read video state from ref, not closure
          if (!isVideoActiveRef.current) {
            const point: ChartPoint = {
              timestamp: new Date(newLog.timestamp).getTime(),
              time: new Date(newLog.timestamp).toLocaleTimeString([], {
                hour: "2-digit",
                minute: "2-digit",
              }),
              focus_score: newLog.focus_score,
            };
            setChartData((prev) => {
              const updated = [...prev, point];
              if (updated.length > 60) updated.shift();
              return updated;
            });
            setCurrentScore(newLog.focus_score);
            setLiveStatus(stateToLabel(newLog.predicted_state));
          }

          // Always track notifications regardless of video mode
          if (newLog.focus_score < 60) {
            const event: NotificationEvent = {
              id: newLog.id ?? `${newLog.timestamp}`,
              timestamp: newLog.timestamp,
              focus_score: newLog.focus_score,
              predicted_state: newLog.predicted_state,
            };
            setNotifications((prev) => [event, ...prev].slice(0, 50));
            setUnreadCount((c) => c + 1);
          }
        }
      )
      .on(
        "postgres_changes",
        { event: "INSERT", schema: "public", table: "focus_sessions" },
        (payload) => {
          const newSession = payload.new as any;
          if (newSession.status === "active") {
            setActiveSessionId(newSession.id);
            activeSessionIdRef.current = newSession.id;
            setSessionStartedAt(
              newSession.started_at
                ? new Date(newSession.started_at).getTime()
                : Date.now()
            );
            setLiveStatus("Waiting for Telemetry…");
            setChartData([]);
            setCurrentScore(0);
            setNotifications([]);
            setUnreadCount(0);
          }
        }
      )
      .on(
        "postgres_changes",
        { event: "UPDATE", schema: "public", table: "focus_sessions" },
        (payload) => {
          const updated = payload.new as any;
          if (updated.status !== "active") {
            setLiveStatus("Device Offline / Session Ended");
            setActiveSessionId(null);
            activeSessionIdRef.current = null;
            setSessionStartedAt(null);
            // Refresh stats after session ends
            fetchInitialData();
          }
        }
      )
      .subscribe();

    return () => {
      supabase
        .from("device_status")
        .upsert({ device_id: "global", is_watching: false });
      supabase.removeChannel(channel);
      if (peerConnectionRef.current) peerConnectionRef.current.close();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []); // ← runs ONCE on mount only

  // ---------------------------------------------------------------------------
  // Bug Fix #1 (cont.) — SEPARATE effect for isVideoActive side-effects
  // ---------------------------------------------------------------------------
  useEffect(() => {
    // When video activates, show an indicator; when it deactivates, nothing extra needed
    if (isVideoActive) {
      setWebrtcStatus("Establishing WebRTC Connection…");
    }
  }, [isVideoActive]);

  // ---------------------------------------------------------------------------
  // WebRTC handlers
  // ---------------------------------------------------------------------------
  const handleLiveVerification = async () => {
    if (!activeSessionIdRef.current) {
      alert("Cannot request live verification — the tablet is currently offline.");
      return;
    }

    setIsVideoActive(true);
    setWebrtcStatus("Initializing WebRTC Handshake…");

    const configuration: RTCConfiguration = {
      iceServers: [{ urls: "stun:stun.l.google.com:19302" }],
    };
    const pc = new RTCPeerConnection(configuration);
    peerConnectionRef.current = pc;

    pc.ontrack = (event) => {
      if (videoRef.current) {
        videoRef.current.srcObject = event.streams[0];
        setWebrtcStatus("");
      }
    };

    pc.onicecandidate = async (event) => {
      if (event.candidate) {
        await supabase.from("webrtc_signaling").insert({
          session_id: activeSessionIdRef.current,
          type: "candidate_parent",
          payload: JSON.parse(JSON.stringify(event.candidate)),
        });
      }
    };

    const signalingChannel = supabase
      .channel("webrtc_parent_listener")
      .on(
        "postgres_changes",
        {
          event: "INSERT",
          schema: "public",
          table: "webrtc_signaling",
          filter: `session_id=eq.${activeSessionIdRef.current}`,
        },
        async (payload) => {
          const record = payload.new as any;
          if (record.type === "answer_tablet") {
            setWebrtcStatus("Received Tablet Answer — Establishing ICE…");
            await pc.setRemoteDescription(
              new RTCSessionDescription(record.payload)
            );
          } else if (record.type === "candidate_tablet") {
            await pc.addIceCandidate(new RTCIceCandidate(record.payload));
          }
        }
      )
      .subscribe();

    pc.addTransceiver("video", { direction: "recvonly" });
    setWebrtcStatus("Generating SDP Offer…");
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    setWebrtcStatus("Transmitting Offer via Supabase…");
    await supabase.from("webrtc_signaling").insert({
      session_id: activeSessionIdRef.current,
      type: "offer_parent",
      payload: { type: offer.type, sdp: offer.sdp, video_request: true },
    });
  };

  const handleTerminateAmbush = async () => {
    setIsVideoActive(false);
    setWebrtcStatus("Video Feed Disconnected");
    if (peerConnectionRef.current) {
      peerConnectionRef.current.close();
      peerConnectionRef.current = null;
    }
    if (activeSessionIdRef.current) {
      await supabase.from("webrtc_signaling").insert({
        session_id: activeSessionIdRef.current,
        type: "stop_ambush",
        payload: {},
      });
    }
  };

  // ---------------------------------------------------------------------------
  // Edge AI score update callback
  // ---------------------------------------------------------------------------
  const handleEdgeScoreUpdate = useCallback((score: number, state: string) => {
    setCurrentScore(score);
    setLiveStatus(state);
    setChartData((prev) => {
      const now = Date.now();
      const updated = [
        ...prev,
        {
          timestamp: now,
          time: new Date(now).toLocaleTimeString([], {
            hour: "2-digit",
            minute: "2-digit",
          }),
          focus_score: score,
        },
      ];
      if (updated.length > 60) updated.shift();
      return updated;
    });
  }, []);

  // ---------------------------------------------------------------------------
  // Notifications tab read
  // ---------------------------------------------------------------------------
  const handleTabChange = (tab: ActiveTab) => {
    setActiveTab(tab);
    if (tab === "notifications") setUnreadCount(0);
  };

  // ---------------------------------------------------------------------------
  // Memoised session stats
  // ---------------------------------------------------------------------------
  const sessionAvg = useMemo(() => {
    if (!chartData.length) return 0;
    return Math.round(
      chartData.reduce((s, p) => s + p.focus_score, 0) / chartData.length
    );
  }, [chartData]);

  // ---------------------------------------------------------------------------
  // Render
  // ---------------------------------------------------------------------------
  return (
    <div
      className="min-h-screen w-full relative overflow-hidden font-sans selection:bg-cyan-500/30"
      style={{ backgroundColor: "#0a0f1e" }}
    >
      {/* ── Background nebula blobs ──────────────────────────────────────── */}
      <div className="absolute inset-0 z-0 overflow-hidden pointer-events-none">
        <div
          className="absolute rounded-full opacity-20"
          style={{
            width: 700,
            height: 700,
            top: "-15%",
            left: "-10%",
            background:
              "radial-gradient(circle, rgba(34,211,238,0.35) 0%, transparent 70%)",
            filter: "blur(60px)",
          }}
        />
        <div
          className="absolute rounded-full opacity-15"
          style={{
            width: 600,
            height: 600,
            bottom: "-10%",
            right: "-5%",
            background:
              "radial-gradient(circle, rgba(99,102,241,0.4) 0%, transparent 70%)",
            filter: "blur(70px)",
          }}
        />
        <div
          className="absolute rounded-full opacity-10"
          style={{
            width: 400,
            height: 400,
            top: "40%",
            left: "50%",
            transform: "translate(-50%, -50%)",
            background:
              "radial-gradient(circle, rgba(16,185,129,0.3) 0%, transparent 70%)",
            filter: "blur(50px)",
          }}
        />
        {/* Subtle grid */}
        <div
          className="absolute inset-0"
          style={{
            backgroundImage:
              "linear-gradient(rgba(34,211,238,0.03) 1px, transparent 1px), linear-gradient(90deg, rgba(34,211,238,0.03) 1px, transparent 1px)",
            backgroundSize: "48px 48px",
          }}
        />
      </div>

      {/* ── Main container ───────────────────────────────────────────────── */}
      <div className="relative z-10 w-full max-w-[1440px] mx-auto px-4 md:px-8 py-6 flex flex-col gap-6 min-h-screen">

        {/* ── Header ─────────────────────────────────────────────────────── */}
        <motion.div
          custom={0}
          variants={cardVariants}
          initial="hidden"
          animate="visible"
          className="flex flex-col md:flex-row justify-between items-start md:items-center gap-4"
        >
          <div>
            <p className="text-cyan-400 text-xs font-bold tracking-[0.25em] uppercase mb-1 flex items-center gap-2">
              <span className="inline-block w-1.5 h-1.5 rounded-full bg-cyan-400 animate-pulse" />
              JEE 2027 — Parent Observer Portal
            </p>
            <h1
              className="text-3xl md:text-4xl text-white leading-tight"
              style={{ fontFamily: '"Playfair Display", serif', fontWeight: 600 }}
            >
              Focus Intelligence Dashboard
            </h1>
            <p className="text-slate-400 text-sm mt-1">
              Monitoring{" "}
              <span className="text-white font-semibold">Sireen Yadav</span> ·{" "}
              {new Date().toLocaleDateString("en-IN", {
                weekday: "long",
                day: "numeric",
                month: "long",
              })}
            </p>
          </div>

          <div className="flex items-center gap-3">
            {/* Live pill */}
            <div
              className="flex items-center gap-2 px-4 py-2 rounded-full text-sm font-semibold"
              style={{
                background: activeSessionId
                  ? "rgba(16,185,129,0.12)"
                  : "rgba(100,116,139,0.12)",
                border: activeSessionId
                  ? "1px solid rgba(16,185,129,0.35)"
                  : "1px solid rgba(100,116,139,0.25)",
                color: activeSessionId ? "#10b981" : "#64748b",
              }}
            >
              {activeSessionId ? (
                <Wifi className="w-4 h-4" />
              ) : (
                <WifiOff className="w-4 h-4" />
              )}
              {activeSessionId ? "Live Link Active" : "Offline"}
            </div>

            {/* Elapsed timer */}
            {activeSessionId && (
              <div
                className="flex items-center gap-2 px-4 py-2 rounded-full text-sm font-mono font-bold"
                style={{
                  background: "rgba(34,211,238,0.08)",
                  border: "1px solid rgba(34,211,238,0.2)",
                  color: "#22d3ee",
                }}
              >
                <Clock className="w-4 h-4" />
                {elapsedDisplay}
              </div>
            )}
          </div>
        </motion.div>

        {/* ── Tab bar ────────────────────────────────────────────────────── */}
        <motion.div
          custom={1}
          variants={cardVariants}
          initial="hidden"
          animate="visible"
          className="flex gap-1 p-1 rounded-2xl self-start"
          style={{
            background: "rgba(255,255,255,0.04)",
            border: "1px solid rgba(255,255,255,0.08)",
          }}
        >
          {(
            [
              { id: "dashboard", label: "Observer Dashboard", Icon: Activity },
              { id: "notifications", label: "Notifications", Icon: Bell },
            ] as { id: ActiveTab; label: string; Icon: any }[]
          ).map(({ id, label, Icon }) => {
            const isActive = activeTab === id;
            return (
              <button
                key={id}
                onClick={() => handleTabChange(id)}
                className="relative flex items-center gap-2 px-5 py-2.5 rounded-xl text-sm font-semibold transition-all duration-300"
                style={{
                  background: isActive
                    ? "rgba(34,211,238,0.15)"
                    : "transparent",
                  color: isActive ? "#22d3ee" : "#64748b",
                  border: isActive
                    ? "1px solid rgba(34,211,238,0.3)"
                    : "1px solid transparent",
                }}
              >
                <Icon className="w-4 h-4" />
                {label}
                {id === "notifications" && unreadCount > 0 && (
                  <span
                    className="absolute -top-1.5 -right-1.5 w-5 h-5 rounded-full text-[10px] font-bold flex items-center justify-center"
                    style={{ background: "#ef4444", color: "#fff" }}
                  >
                    {unreadCount > 9 ? "9+" : unreadCount}
                  </span>
                )}
              </button>
            );
          })}
        </motion.div>

        {/* ── Tab: Observer Dashboard ─────────────────────────────────────── */}
        <AnimatePresence mode="wait">
          {activeTab === "dashboard" && (
            <motion.div
              key="dashboard"
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -12 }}
              transition={{ duration: 0.3 }}
              className="flex flex-col gap-6"
            >
              {/* ── Row 1: Gauge + Chart + WebRTC ──────────────────────── */}
              <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">

                {/* Gauge card */}
                <motion.div
                  custom={2}
                  variants={cardVariants}
                  initial="hidden"
                  animate="visible"
                  className="lg:col-span-3"
                >
                  <div
                    className="rounded-3xl p-6 flex flex-col items-center justify-center gap-4 h-full min-h-[300px]"
                    style={{
                      background:
                        "linear-gradient(135deg, rgba(15,23,42,0.85) 0%, rgba(10,15,30,0.95) 100%)",
                      border: "1px solid rgba(34,211,238,0.15)",
                      boxShadow: "0 8px 40px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.05)",
                      backdropFilter: "blur(20px)",
                    }}
                  >
                    <div className="flex items-center gap-2 self-start">
                      <BrainCircuit className="w-4 h-4 text-cyan-400" />
                      <span className="text-slate-300 text-sm font-semibold">
                        Live Focus Score
                      </span>
                    </div>

                    <FocusRingGauge
                      score={currentScore}
                      state={liveStatus}
                      size={168}
                      strokeWidth={13}
                    />

                    {/* State badge */}
                    <div
                      className="w-full text-center text-xs font-bold uppercase tracking-widest py-2 rounded-xl"
                      style={{
                        background: scoreBg(currentScore),
                        color: scoreColor(currentScore),
                        border: `1px solid ${scoreColor(currentScore)}40`,
                      }}
                    >
                      {liveStatus}
                    </div>

                    {/* Session avg */}
                    {activeSessionId && (
                      <div className="flex justify-between w-full text-xs text-slate-500 mt-1">
                        <span>Session avg</span>
                        <span
                          className="font-bold"
                          style={{ color: scoreColor(sessionAvg) }}
                        >
                          {sessionAvg}%
                        </span>
                      </div>
                    )}
                  </div>
                </motion.div>

                {/* Focus Score Trajectory Chart */}
                <motion.div
                  custom={3}
                  variants={cardVariants}
                  initial="hidden"
                  animate="visible"
                  className="lg:col-span-6"
                >
                  <div
                    className="rounded-3xl p-6 flex flex-col h-full min-h-[300px]"
                    style={{
                      background:
                        "linear-gradient(135deg, rgba(15,23,42,0.85) 0%, rgba(10,15,30,0.95) 100%)",
                      border: "1px solid rgba(34,211,238,0.15)",
                      boxShadow: "0 8px 40px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.05)",
                      backdropFilter: "blur(20px)",
                    }}
                  >
                    {/* Card header */}
                    <div className="flex justify-between items-center mb-4">
                      <div className="flex items-center gap-3">
                        <div className="flex items-center gap-2">
                          <div
                            className="w-9 h-9 rounded-full overflow-hidden border-2"
                            style={{ borderColor: "rgba(34,211,238,0.35)" }}
                          >
                            <img
                              src="https://images.unsplash.com/photo-1539571696357-5a69c17a67c6?q=80&w=200&auto=format&fit=crop"
                              alt="Sireen Yadav"
                              className="w-full h-full object-cover"
                            />
                          </div>
                          <span
                            className="text-white font-semibold"
                            style={{ fontFamily: '"Playfair Display", serif' }}
                          >
                            Sireen Yadav
                          </span>
                        </div>
                      </div>
                      <div
                        className="flex items-center gap-2 px-3 py-1.5 rounded-full text-xs font-bold"
                        style={{
                          background: activeSessionId
                            ? "rgba(34,211,238,0.12)"
                            : "rgba(100,116,139,0.12)",
                          border: activeSessionId
                            ? "1px solid rgba(34,211,238,0.3)"
                            : "1px solid rgba(100,116,139,0.2)",
                          color: activeSessionId ? "#22d3ee" : "#64748b",
                        }}
                      >
                        <span
                          className={`w-1.5 h-1.5 rounded-full ${
                            activeSessionId ? "bg-cyan-400 animate-pulse" : "bg-slate-500"
                          }`}
                        />
                        {activeSessionId ? "Realtime" : "Offline"}
                      </div>
                    </div>

                    {/* Big score number */}
                    <div className="flex items-baseline gap-1 mb-4">
                      <span
                        className="leading-none"
                        style={{
                          fontFamily: '"Playfair Display", serif',
                          fontSize: 52,
                          fontWeight: 700,
                          color: scoreColor(currentScore),
                          textShadow: `0 0 30px ${scoreColor(currentScore)}60`,
                          transition: "color 0.7s ease",
                        }}
                      >
                        {currentScore}
                      </span>
                      <span
                        className="text-xl font-bold"
                        style={{ color: scoreColor(currentScore) }}
                      >
                        %
                      </span>
                      <span className="text-slate-500 text-sm ml-2">focus score</span>
                    </div>

                    {/* Chart */}
                    <div className="flex-grow min-h-0" style={{ height: 150 }}>
                      {chartData.length > 0 ? (
                        <ResponsiveContainer width="100%" height="100%">
                          <AreaChart
                            data={chartData}
                            margin={{ top: 8, right: 0, left: -28, bottom: 0 }}
                          >
                            <defs>
                              <linearGradient
                                id="gradScore"
                                x1="0"
                                y1="0"
                                x2="0"
                                y2="1"
                              >
                                <stop
                                  offset="5%"
                                  stopColor="#22d3ee"
                                  stopOpacity={0.45}
                                />
                                <stop
                                  offset="95%"
                                  stopColor="#22d3ee"
                                  stopOpacity={0}
                                />
                              </linearGradient>
                            </defs>
                            <CartesianGrid
                              strokeDasharray="3 3"
                              stroke="rgba(255,255,255,0.04)"
                              vertical={false}
                            />
                            <XAxis
                              dataKey="time"
                              stroke="transparent"
                              tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 10 }}
                              tickLine={false}
                              interval="preserveStartEnd"
                            />
                            <YAxis
                              domain={[0, 100]}
                              stroke="transparent"
                              tick={{ fill: "rgba(255,255,255,0.3)", fontSize: 10 }}
                              tickLine={false}
                            />
                            <Tooltip content={<CustomTooltip />} />
                            <ReferenceLine
                              y={60}
                              stroke="rgba(239,68,68,0.3)"
                              strokeDasharray="4 4"
                              label={{
                                value: "Alert threshold",
                                position: "insideTopRight",
                                fill: "rgba(239,68,68,0.5)",
                                fontSize: 9,
                              }}
                            />
                            <Area
                              type="monotone"
                              dataKey="focus_score"
                              stroke="#22d3ee"
                              strokeWidth={2.5}
                              fillOpacity={1}
                              fill="url(#gradScore)"
                              dot={false}
                              animationDuration={400}
                            />
                          </AreaChart>
                        </ResponsiveContainer>
                      ) : (
                        <div className="h-full flex items-center justify-center">
                          <p className="text-slate-600 text-sm text-center">
                            {activeSessionId
                              ? "Waiting for first telemetry packet…"
                              : "No active session"}
                          </p>
                        </div>
                      )}
                    </div>
                  </div>
                </motion.div>

                {/* WebRTC video panel */}
                <motion.div
                  custom={4}
                  variants={cardVariants}
                  initial="hidden"
                  animate="visible"
                  className="lg:col-span-3"
                >
                  <div
                    className="rounded-3xl p-5 flex flex-col h-full min-h-[300px]"
                    style={{
                      background:
                        "linear-gradient(135deg, rgba(15,23,42,0.85) 0%, rgba(10,15,30,0.95) 100%)",
                      border: "1px solid rgba(34,211,238,0.15)",
                      boxShadow: "0 8px 40px rgba(0,0,0,0.5), inset 0 1px 0 rgba(255,255,255,0.05)",
                      backdropFilter: "blur(20px)",
                    }}
                  >
                    <div className="flex justify-between items-center mb-3">
                      <span className="text-slate-300 text-sm font-semibold flex items-center gap-2">
                        <Video className="w-4 h-4 text-cyan-400" />
                        Ambush Feed
                      </span>
                      {isVideoActive && (
                        <span
                          className="text-[10px] font-bold uppercase tracking-wider px-2 py-0.5 rounded-full animate-pulse"
                          style={{
                            background: "rgba(239,68,68,0.15)",
                            color: "#ef4444",
                            border: "1px solid rgba(239,68,68,0.3)",
                          }}
                        >
                          LIVE
                        </span>
                      )}
                    </div>

                    {/* Video viewport */}
                    <div
                      className="relative flex-grow rounded-2xl overflow-hidden mb-3"
                      style={{
                        background: "#050810",
                        border: "1px solid rgba(255,255,255,0.07)",
                        minHeight: 180,
                      }}
                    >
                      <video
                        ref={videoRef}
                        autoPlay
                        playsInline
                        muted
                        className="absolute inset-0 w-full h-full object-cover transition-opacity duration-700"
                        style={{ opacity: isVideoActive ? 1 : 0 }}
                      />

                      {!isVideoActive && (
                        <div className="absolute inset-0 flex flex-col items-center justify-center text-center p-4 gap-3">
                          <div
                            className="w-12 h-12 rounded-full flex items-center justify-center"
                            style={{
                              background: "rgba(34,211,238,0.08)",
                              border: "1px solid rgba(34,211,238,0.2)",
                            }}
                          >
                            <Eye className="w-5 h-5 text-slate-500" />
                          </div>
                          <span className="text-slate-500 text-xs uppercase tracking-widest font-semibold leading-tight">
                            {webrtcStatus}
                          </span>
                        </div>
                      )}

                      {isVideoActive && (
                        <div className="absolute inset-0 pointer-events-none">
                          <FaceTrackerEdge
                            videoRef={videoRef}
                            isActive={isVideoActive}
                            onScoreUpdate={handleEdgeScoreUpdate}
                          />
                        </div>
                      )}

                      {/* Scan-line overlay when active */}
                      {isVideoActive && (
                        <div
                          className="absolute inset-0 pointer-events-none"
                          style={{
                            backgroundImage:
                              "repeating-linear-gradient(0deg, transparent, transparent 2px, rgba(0,0,0,0.07) 2px, rgba(0,0,0,0.07) 4px)",
                          }}
                        />
                      )}
                    </div>

                    {/* Action button */}
                    <button
                      onClick={
                        isVideoActive
                          ? handleTerminateAmbush
                          : handleLiveVerification
                      }
                      disabled={!activeSessionId && !isVideoActive}
                      className="w-full py-3 rounded-xl font-bold text-sm tracking-wide transition-all duration-300"
                      style={
                        isVideoActive
                          ? {
                              background: "rgba(239,68,68,0.12)",
                              color: "#ef4444",
                              border: "1px solid rgba(239,68,68,0.3)",
                            }
                          : !activeSessionId
                          ? {
                              background: "rgba(100,116,139,0.1)",
                              color: "#475569",
                              border: "1px solid rgba(100,116,139,0.2)",
                              cursor: "not-allowed",
                            }
                          : {
                              background:
                                "linear-gradient(135deg, rgba(34,211,238,0.2) 0%, rgba(99,102,241,0.2) 100%)",
                              color: "#22d3ee",
                              border: "1px solid rgba(34,211,238,0.35)",
                              boxShadow: "0 0 20px rgba(34,211,238,0.15)",
                            }
                      }
                    >
                      {isVideoActive ? "TERMINATE FEED" : "DEPLOY AMBUSH"}
                    </button>
                  </div>
                </motion.div>
              </div>

              {/* ── Row 2: Stats + Timeline ─────────────────────────────── */}
              <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">

                {/* Stats overview */}
                <motion.div
                  custom={5}
                  variants={cardVariants}
                  initial="hidden"
                  animate="visible"
                  className="lg:col-span-4"
                >
                  <div
                    className="rounded-3xl p-6 flex flex-col gap-4 h-full"
                    style={{
                      background:
                        "linear-gradient(135deg, rgba(15,23,42,0.85) 0%, rgba(10,15,30,0.95) 100%)",
                      border: "1px solid rgba(34,211,238,0.12)",
                      boxShadow: "0 8px 40px rgba(0,0,0,0.4)",
                      backdropFilter: "blur(20px)",
                    }}
                  >
                    <div className="flex items-center gap-2 mb-1">
                      <ActivitySquare className="w-4 h-4 text-cyan-400" />
                      <span className="text-slate-300 font-semibold text-sm">
                        Session Statistics
                      </span>
                    </div>

                    {/* Stat tiles */}
                    <div className="grid grid-cols-2 gap-3">
                      {[
                        {
                          label: "Total Focus Time",
                          value: totalFocusTime,
                          color: "#22d3ee",
                          icon: <Clock className="w-4 h-4" />,
                        },
                        {
                          label: "Avg Score",
                          value: `${avgConsistency}%`,
                          color: scoreColor(avgConsistency),
                          icon: <Zap className="w-4 h-4" />,
                        },
                        {
                          label: "Focus Drops",
                          value: `${focusDrops}`,
                          color: "#f59e0b",
                          icon: <TrendingDown className="w-4 h-4" />,
                        },
                        {
                          label: "Session Avg",
                          value: `${sessionAvg}%`,
                          color: scoreColor(sessionAvg),
                          icon: <Activity className="w-4 h-4" />,
                        },
                      ].map((stat, i) => (
                        <div
                          key={i}
                          className="rounded-2xl p-4"
                          style={{
                            background: "rgba(255,255,255,0.03)",
                            border: "1px solid rgba(255,255,255,0.06)",
                          }}
                        >
                          <div
                            className="flex items-center gap-1.5 mb-2"
                            style={{ color: stat.color, opacity: 0.7 }}
                          >
                            {stat.icon}
                            <span className="text-[10px] font-bold uppercase tracking-wider text-slate-500">
                              {stat.label}
                            </span>
                          </div>
                          <span
                            className="text-2xl font-bold leading-none"
                            style={{
                              fontFamily: '"Playfair Display", serif',
                              color: stat.color,
                              textShadow: `0 0 20px ${stat.color}40`,
                            }}
                          >
                            {stat.value}
                          </span>
                        </div>
                      ))}
                    </div>

                    {/* Consistency bar */}
                    <div className="mt-1">
                      <div className="flex justify-between text-xs mb-2">
                        <span className="text-slate-500 font-medium">
                          Focus Consistency
                        </span>
                        <span
                          className="font-bold"
                          style={{ color: scoreColor(avgConsistency) }}
                        >
                          {avgConsistency >= 80
                            ? "Excellent"
                            : avgConsistency >= 60
                            ? "Good"
                            : avgConsistency >= 40
                            ? "Fair"
                            : "Poor"}
                        </span>
                      </div>
                      <div
                        className="w-full h-2 rounded-full overflow-hidden"
                        style={{ background: "rgba(255,255,255,0.06)" }}
                      >
                        <div
                          className="h-full rounded-full transition-all duration-700"
                          style={{
                            width: `${avgConsistency}%`,
                            background: `linear-gradient(90deg, ${scoreColor(avgConsistency)}, ${scoreColor(avgConsistency)}99)`,
                            boxShadow: `0 0 8px ${scoreColor(avgConsistency)}60`,
                          }}
                        />
                      </div>
                    </div>
                  </div>
                </motion.div>

                {/* Recent session timeline */}
                <motion.div
                  custom={6}
                  variants={cardVariants}
                  initial="hidden"
                  animate="visible"
                  className="lg:col-span-8"
                >
                  <div
                    className="rounded-3xl p-6 flex flex-col h-full"
                    style={{
                      background:
                        "linear-gradient(135deg, rgba(15,23,42,0.85) 0%, rgba(10,15,30,0.95) 100%)",
                      border: "1px solid rgba(34,211,238,0.12)",
                      boxShadow: "0 8px 40px rgba(0,0,0,0.4)",
                      backdropFilter: "blur(20px)",
                    }}
                  >
                    <div className="flex justify-between items-center mb-5">
                      <div className="flex items-center gap-2">
                        <History className="w-4 h-4 text-cyan-400" />
                        <span className="text-slate-300 font-semibold text-sm">
                          Recent Sessions
                        </span>
                      </div>
                      <span
                        className="text-xs font-semibold px-3 py-1.5 rounded-full cursor-pointer transition-all"
                        style={{
                          background: "rgba(34,211,238,0.08)",
                          color: "#22d3ee",
                          border: "1px solid rgba(34,211,238,0.2)",
                        }}
                      >
                        View All
                      </span>
                    </div>

                    <div className="flex flex-col gap-2 overflow-y-auto custom-scrollbar pr-1">
                      {historySessions.length === 0 ? (
                        <div className="text-center text-slate-600 text-sm py-8 font-medium">
                          No completed sessions found
                        </div>
                      ) : (
                        historySessions.map((session, idx) => {
                          // Bug fix: use avg_focus_score column directly from DB
                          const avg = session.avg_focus_score ?? 0;
                          const duration =
                            session.started_at && session.ended_at
                              ? formatDuration(
                                  new Date(session.ended_at).getTime() -
                                    new Date(session.started_at).getTime()
                                )
                              : "—";

                          return (
                            <motion.div
                              key={session.id}
                              custom={idx}
                              variants={cardVariants}
                              initial="hidden"
                              animate="visible"
                              className="flex items-center justify-between p-4 rounded-2xl cursor-pointer transition-all duration-200 group"
                              style={{
                                background: "rgba(255,255,255,0.03)",
                                border: "1px solid rgba(255,255,255,0.06)",
                              }}
                              whileHover={{
                                background: "rgba(34,211,238,0.06)",
                                borderColor: "rgba(34,211,238,0.2)",
                              }}
                            >
                              <div className="flex items-center gap-4">
                                <div
                                  className="w-10 h-10 rounded-xl flex items-center justify-center flex-shrink-0"
                                  style={{
                                    background:
                                      "linear-gradient(135deg, rgba(34,211,238,0.15), rgba(99,102,241,0.15))",
                                    border: "1px solid rgba(34,211,238,0.2)",
                                  }}
                                >
                                  <LayoutDashboard className="w-4 h-4 text-cyan-400" />
                                </div>
                                <div>
                                  <p className="text-white text-sm font-semibold">
                                    {session.subject_tag || "General"}
                                    {session.chapter_name
                                      ? ` — ${session.chapter_name}`
                                      : ""}
                                  </p>
                                  <p className="text-slate-500 text-xs mt-0.5 flex items-center gap-2">
                                    {session.lecture_number
                                      ? `Lecture #${session.lecture_number}`
                                      : "—"}
                                    <span
                                      className="inline-block w-1 h-1 rounded-full bg-slate-600"
                                    />
                                    <span className="text-slate-600">
                                      {session.ended_at
                                        ? new Date(
                                            session.ended_at
                                          ).toLocaleDateString("en-IN", {
                                            day: "numeric",
                                            month: "short",
                                          })
                                        : "—"}
                                    </span>
                                    <span
                                      className="inline-block w-1 h-1 rounded-full bg-slate-600"
                                    />
                                    <Clock className="w-3 h-3 text-slate-600" />
                                    {duration}
                                  </p>
                                </div>
                              </div>

                              <div className="flex items-center gap-3">
                                <div className="text-right">
                                  <span
                                    className="text-2xl font-bold"
                                    style={{
                                      fontFamily: '"Playfair Display", serif',
                                      color: scoreColor(avg),
                                    }}
                                  >
                                    {avg}
                                  </span>
                                  <span
                                    className="text-sm font-bold"
                                    style={{ color: scoreColor(avg) }}
                                  >
                                    %
                                  </span>
                                </div>
                                <ChevronRight
                                  className="w-4 h-4 text-slate-700 group-hover:text-cyan-400 transition-colors"
                                />
                              </div>
                            </motion.div>
                          );
                        })
                      )}
                    </div>
                  </div>
                </motion.div>
              </div>
            </motion.div>
          )}

          {/* ── Tab: Notifications ──────────────────────────────────────── */}
          {activeTab === "notifications" && (
            <motion.div
              key="notifications"
              initial={{ opacity: 0, y: 12 }}
              animate={{ opacity: 1, y: 0 }}
              exit={{ opacity: 0, y: -12 }}
              transition={{ duration: 0.3 }}
            >
              <div
                className="rounded-3xl p-6"
                style={{
                  background:
                    "linear-gradient(135deg, rgba(15,23,42,0.9) 0%, rgba(10,15,30,0.98) 100%)",
                  border: "1px solid rgba(34,211,238,0.12)",
                  boxShadow: "0 8px 40px rgba(0,0,0,0.5)",
                  backdropFilter: "blur(20px)",
                }}
              >
                <div className="flex items-center justify-between mb-6">
                  <div className="flex items-center gap-3">
                    <div
                      className="w-9 h-9 rounded-xl flex items-center justify-center"
                      style={{
                        background: "rgba(239,68,68,0.12)",
                        border: "1px solid rgba(239,68,68,0.25)",
                      }}
                    >
                      <TrendingDown className="w-4 h-4 text-red-400" />
                    </div>
                    <div>
                      <h2 className="text-white font-semibold">
                        Focus Drop Alerts
                      </h2>
                      <p className="text-slate-500 text-xs">
                        Telemetry events where focus score &lt; 60 — active
                        session
                      </p>
                    </div>
                  </div>
                  <span
                    className="text-xs font-bold px-3 py-1.5 rounded-full"
                    style={{
                      background: "rgba(239,68,68,0.12)",
                      color: "#ef4444",
                      border: "1px solid rgba(239,68,68,0.25)",
                    }}
                  >
                    {notifications.length} Events
                  </span>
                </div>

                {notifications.length === 0 ? (
                  <div className="flex flex-col items-center justify-center py-20 gap-4 text-slate-600">
                    <CheckCircle2 className="w-12 h-12 text-emerald-700" />
                    <p className="text-sm font-medium text-center">
                      No focus drops detected in this session.
                      <br />
                      <span className="text-slate-700">
                        Sireen is staying focused! 🎯
                      </span>
                    </p>
                  </div>
                ) : (
                  <div className="flex flex-col gap-2 max-h-[520px] overflow-y-auto custom-scrollbar pr-1">
                    {notifications.map((n, idx) => (
                      <motion.div
                        key={n.id}
                        custom={idx}
                        variants={cardVariants}
                        initial="hidden"
                        animate="visible"
                        className="flex items-center justify-between p-4 rounded-2xl"
                        style={{
                          background: "rgba(239,68,68,0.05)",
                          border: "1px solid rgba(239,68,68,0.15)",
                        }}
                      >
                        <div className="flex items-center gap-4">
                          <div
                            className="w-9 h-9 rounded-xl flex items-center justify-center flex-shrink-0"
                            style={{
                              background: "rgba(239,68,68,0.12)",
                              border: "1px solid rgba(239,68,68,0.2)",
                            }}
                          >
                            <AlertCircle className="w-4 h-4 text-red-400" />
                          </div>
                          <div>
                            <p className="text-white text-sm font-semibold">
                              Focus Drop Detected
                            </p>
                            <p className="text-slate-500 text-xs mt-0.5">
                              {stateToLabel(n.predicted_state)} ·{" "}
                              {new Date(n.timestamp).toLocaleTimeString([], {
                                hour: "2-digit",
                                minute: "2-digit",
                                second: "2-digit",
                              })}
                            </p>
                          </div>
                        </div>
                        <div
                          className="text-right px-3 py-1.5 rounded-xl"
                          style={{
                            background: "rgba(239,68,68,0.1)",
                            border: "1px solid rgba(239,68,68,0.2)",
                          }}
                        >
                          <span
                            className="text-xl font-bold"
                            style={{
                              fontFamily: '"Playfair Display", serif',
                              color: scoreColor(n.focus_score),
                            }}
                          >
                            {n.focus_score}
                          </span>
                          <span
                            className="text-sm font-bold"
                            style={{ color: scoreColor(n.focus_score) }}
                          >
                            %
                          </span>
                        </div>
                      </motion.div>
                    ))}
                  </div>
                )}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
      </div>

      {/* ── Global styles ─────────────────────────────────────────────────── */}
      <style
        dangerouslySetInnerHTML={{
          __html: `
          @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:ital,wght@0,500;0,600;0,700;1,500&display=swap');

          * { box-sizing: border-box; }

          body {
            font-family: 'Inter', sans-serif;
            background-color: #0a0f1e;
            color: #f8fafc;
            margin: 0;
          }

          .custom-scrollbar::-webkit-scrollbar { width: 4px; }
          .custom-scrollbar::-webkit-scrollbar-track {
            background: rgba(255,255,255,0.02);
            border-radius: 4px;
          }
          .custom-scrollbar::-webkit-scrollbar-thumb {
            background: rgba(34,211,238,0.2);
            border-radius: 4px;
          }
          .custom-scrollbar::-webkit-scrollbar-thumb:hover {
            background: rgba(34,211,238,0.4);
          }
        `,
        }}
      />
    </div>
  );
}
