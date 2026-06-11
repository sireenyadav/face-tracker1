"use client";

import React, { useState, useEffect, useRef, useCallback } from "react";
import { createClient } from "@supabase/supabase-js";
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts";
import { ShieldAlert, Video, BrainCircuit, ActivitySquare, LayoutDashboard, History, PowerOff, CheckCircle2, AlertCircle, Clock, BatteryMedium, MoreHorizontal, Activity } from "lucide-react";
import { FaceTrackerEdge } from "./components/FaceTrackerEdge";
import { GlassCard } from "./components/GlassCard";
import { motion, AnimatePresence } from "framer-motion";

const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || "https://crmjzxhlggfpisknbjrr.supabase.co";
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8";
const supabase = createClient(supabaseUrl, supabaseAnonKey);

export default function ObserverDashboard() {
  const [data, setData] = useState<any[]>([]);
  const [liveStatus, setLiveStatus] = useState("Waiting for Telemetry...");
  const [currentScore, setCurrentScore] = useState(0);
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
  const [isVideoActive, setIsVideoActive] = useState(false);
  const [webrtcStatus, setWebrtcStatus] = useState("Video Feed Disconnected");
  const [historySessions, setHistorySessions] = useState<any[]>([]);
  
  const videoRef = useRef<HTMLVideoElement>(null);
  const peerConnectionRef = useRef<RTCPeerConnection | null>(null);

  // Computed Stats
  const [totalFocusTime, setTotalFocusTime] = useState("00:00");
  const [avgConsistency, setAvgConsistency] = useState(0);
  const [focusDrops, setFocusDrops] = useState(0);

  useEffect(() => {
    supabase.from("device_status").upsert({ device_id: "global", is_watching: true });

    const fetchInitialData = async () => {
      // Fetch Active Session
      const { data: sessionData } = await supabase
        .from('focus_sessions')
        .select('*')
        .eq('status', 'active')
        .order('started_at', { ascending: false })
        .limit(1);
        
      if (sessionData && sessionData.length > 0) {
        setActiveSessionId(sessionData[0].id);
        const { data: logs } = await supabase
          .from('telemetry_logs')
          .select('*')
          .eq('session_id', sessionData[0].id)
          .order('timestamp', { ascending: true });
          
        if (logs && logs.length > 0) {
          const formatted = logs.map(log => ({
            timestamp: new Date(log.timestamp).getTime(),
            time: new Date(log.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
            focus_score: log.focus_score
          }));
          setData(formatted);
          setCurrentScore(logs[logs.length - 1].focus_score);
          setLiveStatus(logs[logs.length - 1].predicted_state);
        } else {
            setLiveStatus("Waiting for Data...");
        }
      } else {
        setLiveStatus("Device Offline / Session Ended");
      }

      // Fetch History Sessions & Calculate Stats
      const { data: historyData } = await supabase
        .from('focus_sessions')
        .select('*')
        .eq('status', 'completed')
        .order('ended_at', { ascending: false });
        
      if (historyData) {
        setHistorySessions(historyData.slice(0, 5)); // Only show top 5 in timeline
        
        // Calculate Stats
        let totalMinutes = 0;
        let totalScore = 0;
        let validSessions = 0;
        
        historyData.forEach(s => {
          if (s.started_at && s.ended_at) {
            const start = new Date(s.started_at);
            const end = new Date(s.ended_at);
            totalMinutes += Math.floor((end.getTime() - start.getTime()) / 60000);
            validSessions++;
            // Assuming average score would normally come from aggregations, mocking a bit based on session length
            totalScore += 80 + Math.random() * 10; 
          }
        });
        
        const h = Math.floor(totalMinutes / 60);
        const m = totalMinutes % 60;
        setTotalFocusTime(`${h.toString().padStart(2, '0')}:${m.toString().padStart(2, '0')}`);
        setAvgConsistency(validSessions > 0 ? Math.round(totalScore / validSessions) : 0);
        setFocusDrops(Math.floor(Math.random() * 10)); // Mocks penalties for now
      }
    };
    
    fetchInitialData();

    const channel = supabase
      .channel('schema-db-changes')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'telemetry_logs' },
        (payload) => {
          const newLog = payload.new;
          setActiveSessionId((currentActiveId) => {
            if (newLog.session_id === currentActiveId && !isVideoActive) {
                const formatted = {
                  timestamp: new Date(newLog.timestamp).getTime(),
                  time: new Date(newLog.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
                  focus_score: newLog.focus_score
                };
                setData((prev) => {
                   const updated = [...prev, formatted];
                   if (updated.length > 50) updated.shift();
                   return updated;
                });
                setCurrentScore(newLog.focus_score);
                setLiveStatus(newLog.predicted_state);
            }
            return currentActiveId;
          });
        }
      )
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'focus_sessions' }, (payload) => {
          if (payload.new.status === 'active') {
             setActiveSessionId(payload.new.id);
             setLiveStatus("Waiting for Telemetry...");
             setData([]);
             setCurrentScore(0);
          }
      })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'focus_sessions' }, (payload) => {
          if (payload.new.status !== 'active') {
             setLiveStatus("Device Offline / Session Ended");
             setActiveSessionId(null);
          }
      })
      .subscribe();

    return () => {
      supabase.from("device_status").upsert({ device_id: "global", is_watching: false });
      supabase.removeChannel(channel);
      if (peerConnectionRef.current) peerConnectionRef.current.close();
    };
  }, [isVideoActive]);

  const handleLiveVerification = async () => {
    if (!activeSessionId) {
        alert("Cannot request live verification. The tablet is currently offline.");
        return;
    }
    
    setIsVideoActive(true);
    setWebrtcStatus("Initializing WebRTC Handshake...");
    
    const configuration = { iceServers: [{ urls: 'stun:stun.l.google.com:19302' }] };
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
        await supabase.from('webrtc_signaling').insert({
          session_id: activeSessionId,
          type: 'candidate_parent',
          payload: JSON.parse(JSON.stringify(event.candidate))
        });
      }
    };

    const signalingChannel = supabase.channel('webrtc_parent_listener')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'webrtc_signaling', filter: `session_id=eq.${activeSessionId}` }, async (payload) => {
          const record = payload.new;
          if (record.type === 'answer_tablet') {
             setWebrtcStatus("Received Tablet Answer. Establishing ICE...");
             await pc.setRemoteDescription(new RTCSessionDescription(record.payload));
          } else if (record.type === 'candidate_tablet') {
             await pc.addIceCandidate(new RTCIceCandidate(record.payload));
          }
        }
      ).subscribe();

    pc.addTransceiver('video', { direction: 'recvonly' });
    setWebrtcStatus("Generating SDP Offer...");
    const offer = await pc.createOffer();
    await pc.setLocalDescription(offer);

    setWebrtcStatus("Transmitting Offer via Supabase...");
    await supabase.from('webrtc_signaling').insert({
      session_id: activeSessionId,
      type: 'offer_parent',
      payload: { type: offer.type, sdp: offer.sdp }
    });
  };

  const handleTerminateAmbush = async () => {
    if (!activeSessionId) return;
    setIsVideoActive(false);
    setWebrtcStatus("Video Feed Disconnected");
    if (peerConnectionRef.current) {
      peerConnectionRef.current.close();
    }
    await supabase.from('webrtc_signaling').insert({
      session_id: activeSessionId,
      type: 'stop_ambush',
      payload: {}
    });
  };

  const handleEdgeScoreUpdate = useCallback((score: number, state: string) => {
    setCurrentScore(score);
    setLiveStatus(state);
    setData(prev => {
       const now = Date.now();
       const updated = [...prev, {
          timestamp: now,
          time: new Date(now).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' }),
          focus_score: score
       }];
       if (updated.length > 50) updated.shift();
       return updated;
    });
  }, []);

  return (
    <div className="min-h-screen w-full relative bg-slate-50 overflow-hidden font-sans text-slate-800 selection:bg-cyan-500/30">
      {/* Light Frosted Snowy Background */}
      <div 
        className="absolute inset-0 z-0 bg-cover bg-center object-cover opacity-90 transition-opacity duration-1000"
        style={{
          backgroundImage: 'url("https://images.unsplash.com/photo-1542601098-8fc114e148e2?q=80&w=2000&auto=format&fit=crop")',
          filter: 'blur(10px) brightness(1.1)'
        }}
      />
      <div className="absolute inset-0 z-0 bg-gradient-to-br from-white/60 via-slate-50/40 to-cyan-50/20" />

      {/* Main Glass Dashboard Container */}
      <div className="relative z-10 w-full max-w-[1400px] mx-auto p-4 md:p-8 min-h-screen flex flex-col justify-center">
        
        <GlassCard variant="light" className="w-full shadow-2xl p-6">
          {/* Header */}
          <div className="flex flex-col md:flex-row justify-between items-start md:items-center mb-8">
            <div>
              <h1 className="text-4xl font-serif text-slate-800 drop-shadow-sm mb-1" style={{ fontFamily: '"Playfair Display", serif' }}>Parent Observer Dashboard</h1>
              <p className="text-sm font-medium text-slate-500 tracking-wide">Real-time Focus Monitoring</p>
            </div>
            
            <div className="flex items-center space-x-4 mt-4 md:mt-0 text-sm font-semibold text-slate-600 bg-white/40 px-4 py-2 rounded-full shadow-sm border border-white/60">
              <span className="flex items-center"><Clock className="w-4 h-4 mr-2 text-slate-400"/> {new Date().toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric'})}</span>
              <span className="flex items-center text-emerald-600"><BatteryMedium className="w-4 h-4 mr-1"/> Live Link</span>
              <MoreHorizontal className="w-5 h-5 ml-2 cursor-pointer hover:text-slate-900 transition-colors" />
            </div>
          </div>

          {/* Bento Box Grid Layout */}
          <div className="grid grid-cols-1 lg:grid-cols-12 gap-6">
            
            {/* Left Column (Spans 8 cols) */}
            <div className="lg:col-span-8 flex flex-col gap-6">
              
              {/* Top Row in Left Column */}
              <div className="grid grid-cols-1 md:grid-cols-3 gap-6 h-[360px]">
                
                {/* Main Focus Chart (Spans 2 cols) - Contrast Dark Card */}
                <GlassCard variant="dark" className="md:col-span-2 flex flex-col p-6 shadow-2xl">
                  <div className="flex justify-between items-center mb-4">
                    <h3 className="font-semibold text-slate-100 flex items-center">Focus Score Trajectory</h3>
                    <div className="px-3 py-1 rounded-full bg-cyan-500/20 text-cyan-300 text-xs font-bold border border-cyan-500/30 flex items-center shadow-[0_0_15px_rgba(6,182,212,0.3)]">
                      <span className="w-2 h-2 rounded-full bg-cyan-400 mr-2 animate-pulse"></span>
                      {liveStatus}
                    </div>
                  </div>
                  
                  {/* Student Profile Header inside Chart */}
                  <div className="flex justify-between items-end mb-6 z-10 relative">
                     <div className="flex items-center space-x-3">
                        <div className="w-12 h-12 rounded-full overflow-hidden border-2 border-white/20 shadow-lg">
                          <img src="https://images.unsplash.com/photo-1539571696357-5a69c17a67c6?q=80&w=200&auto=format&fit=crop" alt="Sireen Yadav" className="w-full h-full object-cover" />
                        </div>
                        <span className="font-serif text-2xl tracking-wide text-white">Sireen Yadav</span>
                     </div>
                     <div className="flex items-baseline space-x-1">
                        <span className="font-serif text-5xl text-white drop-shadow-lg">{currentScore}</span>
                        <span className="text-cyan-400 font-bold text-xl">%</span>
                     </div>
                  </div>

                  <div className="flex-grow -mx-2 -mb-2 mt-[-40px]">
                    <ResponsiveContainer width="100%" height="100%">
                      <AreaChart data={data} margin={{ top: 10, right: 0, left: -20, bottom: 0 }}>
                        <defs>
                          <linearGradient id="colorScore" x1="0" y1="0" x2="0" y2="1">
                            <stop offset="5%" stopColor="#22d3ee" stopOpacity={0.6}/>
                            <stop offset="95%" stopColor="#22d3ee" stopOpacity={0}/>
                          </linearGradient>
                        </defs>
                        <XAxis 
                          dataKey="time" 
                          stroke="rgba(255,255,255,0.2)" 
                          tick={{ fill: 'rgba(255,255,255,0.4)', fontSize: 10 }} 
                          tickLine={false}
                          axisLine={false}
                        />
                        <YAxis 
                          domain={[0, 100]} 
                          stroke="transparent" 
                          tick={{ fill: 'rgba(255,255,255,0.4)', fontSize: 10 }}
                        />
                        <Tooltip 
                          contentStyle={{ backgroundColor: 'rgba(15, 23, 42, 0.9)', borderColor: 'rgba(255,255,255,0.1)', borderRadius: '12px' }}
                          itemStyle={{ color: '#22d3ee' }}
                        />
                        <Area 
                          type="monotone" 
                          dataKey="focus_score" 
                          stroke="#22d3ee" 
                          strokeWidth={3}
                          fillOpacity={1} 
                          fill="url(#colorScore)" 
                          animationDuration={500}
                        />
                      </AreaChart>
                    </ResponsiveContainer>
                  </div>
                </GlassCard>

                {/* WebRTC Terminal (Spans 1 col) */}
                <GlassCard variant="light" className="flex flex-col p-5 bg-white/50 border border-white/80 shadow-lg">
                  <div className="flex justify-between items-center mb-4">
                    <h3 className="font-semibold text-sm text-slate-800">WebRTC Terminal</h3>
                    <Video className="w-4 h-4 text-slate-400" />
                  </div>
                  
                  <div className="relative flex-grow rounded-2xl overflow-hidden bg-slate-900 border border-white/20 mb-4 shadow-inner group">
                    <video 
                      ref={videoRef} 
                      autoPlay 
                      playsInline 
                      muted 
                      className={`absolute inset-0 w-full h-full object-cover ${isVideoActive ? 'opacity-100' : 'opacity-0'} transition-opacity duration-700`}
                    />
                    
                    {!isVideoActive && (
                      <div className="absolute inset-0 flex flex-col items-center justify-center text-center p-4 bg-slate-800">
                        <img src="https://images.unsplash.com/photo-1427504494785-319ce5154c41?q=80&w=400&auto=format&fit=crop" className="absolute inset-0 opacity-20 object-cover w-full h-full grayscale mix-blend-overlay" />
                        <ShieldAlert className="w-8 h-8 text-slate-400 mb-2 relative z-10" />
                        <span className="text-xs font-semibold text-slate-300 relative z-10 uppercase tracking-widest">{webrtcStatus}</span>
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
                  </div>
                  
                  <button 
                    onClick={isVideoActive ? handleTerminateAmbush : handleLiveVerification}
                    disabled={!activeSessionId && !isVideoActive}
                    className={`w-full py-3.5 rounded-xl font-bold text-sm tracking-wide transition-all duration-300 shadow-md ${
                      isVideoActive 
                        ? "bg-red-50 text-red-600 border border-red-200 hover:bg-red-100" 
                        : "bg-gradient-to-r from-blue-500 to-cyan-500 text-white hover:brightness-110 hover:shadow-cyan-500/20"
                    } ${( !activeSessionId && !isVideoActive ) ? 'opacity-50 cursor-not-allowed' : ''}`}
                  >
                    {isVideoActive ? "TERMINATE FEED" : "DEPLOY AMBUSH"}
                  </button>
                </GlassCard>

              </div>

              {/* Personal Overview (Bottom Left - Fixed Breakage) */}
              <div className="grid grid-cols-1 md:grid-cols-2 gap-6 h-[140px]">
                <GlassCard variant="light" className="flex flex-col justify-center p-6 bg-white/40">
                  <div className="flex items-center justify-between mb-4">
                    <div>
                      <h3 className="font-semibold text-slate-800">Session Projections</h3>
                      <p className="text-xs text-slate-500">Live estimates</p>
                    </div>
                    <Clock className="w-5 h-5 text-slate-400" />
                  </div>
                  <div className="flex space-x-6">
                     <div className="flex-1 flex flex-col">
                        <div className="flex justify-between items-end mb-2">
                           <span className="text-xs font-semibold text-slate-600">Focus Score</span>
                           <span className="font-serif text-2xl text-slate-800">80<span className="text-sm">%</span></span>
                        </div>
                        <div className="w-full h-2 bg-slate-200/50 rounded-full overflow-hidden shadow-inner">
                           <div className="h-full bg-cyan-400 rounded-full w-[80%] shadow-sm"></div>
                        </div>
                     </div>
                     
                     <div className="flex-1 flex flex-col">
                        <div className="flex justify-between items-end mb-2">
                           <span className="text-xs font-semibold text-slate-600">Time Elapsed</span>
                           <span className="font-serif text-2xl text-slate-800">60<span className="text-sm font-sans text-slate-500 ml-1">m</span></span>
                        </div>
                        <div className="w-full h-2 bg-slate-200/50 rounded-full overflow-hidden shadow-inner">
                           <div className="h-full bg-blue-400 rounded-full w-[45%]"></div>
                        </div>
                     </div>
                  </div>
                </GlassCard>

                <GlassCard variant="light" className="flex flex-col justify-center p-6 bg-white/40">
                  <h3 className="font-semibold text-slate-800 mb-3">Focus Breakdown</h3>
                  <div className="space-y-2.5">
                    <div className="flex items-center justify-between text-sm">
                      <div className="flex items-center"><div className="w-2.5 h-2.5 rounded-full bg-emerald-400 mr-3 shadow-sm"></div><span className="text-slate-700 font-medium">Physics</span></div>
                      <span className="text-slate-500 text-xs font-medium bg-white/50 px-2 py-1 rounded-md">Lec #11 • 1 min</span>
                    </div>
                    <div className="flex items-center justify-between text-sm">
                      <div className="flex items-center"><div className="w-2.5 h-2.5 rounded-full bg-blue-400 mr-3 shadow-sm"></div><span className="text-slate-700 font-medium">Chemistry</span></div>
                      <span className="text-slate-500 text-xs font-medium bg-white/50 px-2 py-1 rounded-md">Lec #11 • 2 min</span>
                    </div>
                    <div className="flex items-center justify-between text-sm">
                      <div className="flex items-center"><div className="w-2.5 h-2.5 rounded-full bg-cyan-400 mr-3 shadow-sm"></div><span className="text-slate-700 font-medium">Maths</span></div>
                      <span className="text-slate-500 text-xs font-medium bg-white/50 px-2 py-1 rounded-md">Lec #11 • 2 min</span>
                    </div>
                  </div>
                </GlassCard>
              </div>

            </div>

            {/* Right Column (Spans 4 cols) */}
            <div className="lg:col-span-4 flex flex-col gap-6">
              
              {/* Stats Overview */}
              <GlassCard variant="light" className="p-6 bg-white/50 flex flex-col">
                <h3 className="font-semibold mb-6 flex items-center text-slate-800"><ActivitySquare className="w-5 h-5 mr-2 text-slate-400" /> Stats Overview</h3>
                
                <div className="grid grid-cols-2 gap-4 mb-4">
                  <div className="bg-white/60 p-4 rounded-2xl border border-white/80 shadow-sm">
                    <span className="text-xs text-slate-500 block mb-1 font-medium">Total Focus</span>
                    <span className="font-serif text-3xl text-slate-800">{totalFocusTime}</span>
                  </div>
                  <div className="bg-white/60 p-4 rounded-2xl border border-white/80 shadow-sm">
                    <span className="text-xs text-slate-500 block mb-1 font-medium">Avg Score</span>
                    <span className="font-serif text-3xl text-cyan-600">{avgConsistency}%</span>
                  </div>
                </div>
                
                <div className="bg-white/60 p-5 rounded-2xl border border-white/80 shadow-sm flex justify-between items-center mb-4">
                  <div>
                    <span className="text-xs text-slate-500 block mb-1 flex items-center font-medium"><BrainCircuit className="w-4 h-4 mr-1"/> Focus Consistency</span>
                    <div className="flex items-center mt-2">
                      <div className="w-24 h-2 bg-slate-200/80 rounded-full mr-3 overflow-hidden">
                        <div className="h-full bg-emerald-400" style={{ width: `${avgConsistency}%` }}></div>
                      </div>
                      <span className="text-[11px] font-bold text-emerald-500 uppercase tracking-wide">Good</span>
                    </div>
                  </div>
                  <span className="font-serif text-3xl text-slate-800">{avgConsistency}%</span>
                </div>

                <div className="bg-white/60 p-5 rounded-2xl border border-white/80 shadow-sm flex justify-between items-center">
                  <div>
                    <span className="text-xs text-slate-500 block mb-1 font-medium">Focus Dips</span>
                    <span className="text-[11px] text-slate-400">Vision lost &lt; 20s</span>
                  </div>
                  <span className="font-serif text-4xl text-slate-700">{focusDrops}</span>
                </div>
              </GlassCard>

              {/* Recent Timeline */}
              <GlassCard variant="light" className="flex-grow p-6 flex flex-col bg-white/50">
                <h3 className="font-semibold mb-5 flex items-center justify-between text-slate-800">
                  <span className="flex items-center"><History className="w-5 h-5 mr-2 text-slate-400" /> Recent Timeline</span>
                  <span className="text-xs font-semibold text-cyan-600 bg-cyan-50 px-3 py-1 rounded-full cursor-pointer hover:bg-cyan-100 transition-colors">View All</span>
                </h3>
                
                <div className="flex-grow overflow-y-auto space-y-3 pr-2 custom-scrollbar">
                  {historySessions.length === 0 ? (
                    <div className="text-center text-slate-400 mt-10 text-sm font-medium">No recent sessions found</div>
                  ) : (
                    historySessions.map((session, idx) => {
                      const fakeScore = 70 + (idx * 5) % 30; 
                      return (
                        <div key={session.id} className="flex justify-between items-center p-4 rounded-2xl bg-white/60 border border-white/80 hover:bg-white/80 transition-colors cursor-pointer shadow-sm">
                          <div className="flex items-center">
                            <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-cyan-100 to-blue-100 flex items-center justify-center mr-4 border border-white">
                              <LayoutDashboard className="w-5 h-5 text-cyan-600" />
                            </div>
                            <div>
                              <p className="text-sm font-bold text-slate-700">{session.subject_tag}</p>
                              <p className="text-xs text-slate-500 mt-0.5">{session.chapter_name || 'General'} • Lec #{session.lecture_number}</p>
                            </div>
                          </div>
                          <div className="text-right bg-slate-50 px-3 py-1 rounded-lg border border-slate-100">
                            <span className={`font-serif text-xl ${fakeScore >= 80 ? 'text-emerald-500' : 'text-amber-500'}`}>{fakeScore}</span>
                          </div>
                        </div>
                      )
                    })
                  )}
                </div>
              </GlassCard>

            </div>

          </div>

          {/* Bottom Tabs */}
          <div className="mt-8 flex justify-center space-x-8 border-t border-slate-200/50 pt-6">
            <button className="flex items-center space-x-2 text-slate-800 border-b-2 border-slate-800 pb-2 px-4 text-sm font-bold">
              <Activity className="w-4 h-4" />
              <span>Observer Dashboard</span>
            </button>
            <button className="flex items-center space-x-2 text-slate-400 hover:text-slate-600 pb-2 px-4 text-sm font-semibold transition-colors">
              <AlertCircle className="w-4 h-4" />
              <span>Notifications</span>
            </button>
          </div>

        </GlassCard>

      </div>
      
      {/* Global styles for scrollbar and fonts */}
      <style dangerouslySetInnerHTML={{__html: `
        @import url('https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Playfair+Display:ital,wght@0,500;0,600;0,700;1,500&display=swap');
        
        body {
          font-family: 'Inter', sans-serif;
        }
        
        .custom-scrollbar::-webkit-scrollbar {
          width: 6px;
        }
        .custom-scrollbar::-webkit-scrollbar-track {
          background: rgba(0, 0, 0, 0.02);
          border-radius: 6px;
        }
        .custom-scrollbar::-webkit-scrollbar-thumb {
          background: rgba(34, 211, 238, 0.3);
          border-radius: 6px;
        }
        .custom-scrollbar::-webkit-scrollbar-thumb:hover {
          background: rgba(34, 211, 238, 0.5);
        }
      `}} />
    </div>
  );
}
