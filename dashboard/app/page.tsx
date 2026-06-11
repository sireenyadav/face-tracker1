"use client";

import React, { useState, useEffect, useRef } from "react";
import { createClient } from "@supabase/supabase-js";
import { AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip, ResponsiveContainer } from "recharts";

// Initialize Supabase Client
const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL || "https://crmjzxhlggfpisknbjrr.supabase.co";
const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImNybWp6eGhsZ2dmcGlza25ianJyIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MTE3MjMxOCwiZXhwIjoyMDk2NzQ4MzE4fQ.8CoDj9TVVuScYfTEvrF8kc99E5JpNOXGF-NJVj6SvQ8";
const supabase = createClient(supabaseUrl, supabaseAnonKey);

export default function ObserverDashboard() {
  const [data, setData] = useState<any[]>([]);
  const [liveStatus, setLiveStatus] = useState("Waiting for Telemetry...");
  const [currentScore, setCurrentScore] = useState(0);
  const [activeSessionId, setActiveSessionId] = useState<string | null>(null);
  const [isVideoActive, setIsVideoActive] = useState(false);
  const [webrtcStatus, setWebrtcStatus] = useState("Video Feed Disconnected\n(Awaiting Phase 4 WebRTC Hookup)");
  
  const videoRef = useRef<HTMLVideoElement>(null);
  const peerConnectionRef = useRef<RTCPeerConnection | null>(null);

  useEffect(() => {
    // 1. Tell Android we are watching (Triggers 1-second live stream mode)
    const notifyParentWatching = async () => {
      await supabase.from("device_status").upsert({ device_id: "global", is_watching: true });
    };
    notifyParentWatching();

    // 2. Fetch Active Session and History
    const fetchHistory = async () => {
      const { data: sessionData } = await supabase
        .from('focus_sessions')
        .select('id, status')
        .eq('status', 'active')
        .order('started_at', { ascending: false })
        .limit(1);
        
      if (sessionData && sessionData.length > 0 && sessionData[0].status === 'active') {
        setActiveSessionId(sessionData[0].id);
        
        // Fetch logs
        const { data: logs } = await supabase
          .from('telemetry_logs')
          .select('*')
          .eq('session_id', sessionData[0].id)
          .order('timestamp', { ascending: false })
          .limit(60);
          
        if (logs && logs.length > 0) {
          const formatted = logs.reverse().map(log => ({
            time: new Date(log.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }),
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
        setCurrentScore(0);
        setData([]);
      }
    };
    fetchHistory();

    // 3. Subscribe to LIVE telemetry & session updates
    const channel = supabase
      .channel('schema-db-changes')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'telemetry_logs' },
        (payload) => {
          const newLog = payload.new;
          // Only update if it belongs to the current active session
          setActiveSessionId((currentActiveId) => {
            if (newLog.session_id === currentActiveId) {
                const formatted = {
                  time: new Date(newLog.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }),
                  focus_score: newLog.focus_score
                };
                
                setData((prev) => {
                  const updated = [...prev, formatted];
                  if (updated.length > 60) updated.shift();
                  return updated;
                });
                
                setCurrentScore(newLog.focus_score);
                setLiveStatus(newLog.predicted_state);
            }
            return currentActiveId;
          });
        }
      )
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'focus_sessions' },
        (payload) => {
          if (payload.new.status === 'active') {
             setActiveSessionId(payload.new.id);
             setLiveStatus("Waiting for Telemetry...");
             setData([]);
             setCurrentScore(0);
          }
        }
      )
      .on(
        'postgres_changes',
        { event: 'UPDATE', schema: 'public', table: 'focus_sessions' },
        (payload) => {
          if (payload.new.status !== 'active') {
             setLiveStatus("Device Offline / Session Ended");
             setActiveSessionId(null);
             setData([]);
             setCurrentScore(0);
          }
        }
      )
      .subscribe();

    // Cleanup: Turn off live stream mode
    return () => {
      supabase.from("device_status").upsert({ device_id: "global", is_watching: false });
      supabase.removeChannel(channel);
      if (peerConnectionRef.current) {
          peerConnectionRef.current.close();
      }
    };
  }, []);

  const handleLiveVerification = async () => {
    if (!activeSessionId) {
        alert("Cannot request live verification. The tablet is currently offline or the session has ended.");
        return;
    }
    
    setIsVideoActive(true);
    setWebrtcStatus("Initializing WebRTC Handshake...");
    
    const configuration = {
      iceServers: [{ urls: 'stun:stun.l.google.com:19302' }]
    };
    
    const pc = new RTCPeerConnection(configuration);
    peerConnectionRef.current = pc;

    pc.ontrack = (event) => {
      if (videoRef.current) {
        videoRef.current.srcObject = event.streams[0];
        setWebrtcStatus(""); // Clear status when video arrives
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

    // Listen for Answer and Candidates from Tablet
    console.log("Subscribing to webrtc_parent_listener for session:", activeSessionId);
    const signalingChannel = supabase.channel('webrtc_parent_listener')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'webrtc_signaling', filter: `session_id=eq.${activeSessionId}` },
        async (payload) => {
          const record = payload.new;
          console.log("REALTIME RECEIVED:", record.type, record.payload);
          if (record.type === 'answer_tablet') {
             console.log("Setting Remote Description (Answer)...");
             setWebrtcStatus("Received Tablet Answer. Establishing ICE...");
             await pc.setRemoteDescription(new RTCSessionDescription(record.payload));
             console.log("Remote Description Set!");
          } else if (record.type === 'candidate_tablet') {
             console.log("Adding ICE Candidate...");
             await pc.addIceCandidate(new RTCIceCandidate(record.payload));
          }
        }
      )
      .subscribe((status) => {
         console.log("Realtime subscription status:", status);
      });

    // Add transceivers to trigger offer generation
    console.log("Adding transceivers...");
    pc.addTransceiver('video', { direction: 'recvonly' });
    pc.addTransceiver('audio', { direction: 'recvonly' });

    setWebrtcStatus("Generating SDP Offer...");
    console.log("Creating SDP Offer...");
    const offer = await pc.createOffer();
    
    console.log("Setting Local Description...");
    await pc.setLocalDescription(offer);

    setWebrtcStatus("Transmitting Offer to Tablet via Supabase Realtime...");
    console.log("Inserting offer_parent into Supabase...");
    const { error } = await supabase.from('webrtc_signaling').insert({
      session_id: activeSessionId,
      type: 'offer_parent',
      payload: { type: offer.type, sdp: offer.sdp }
    });
    
    if (error) {
       console.error("SUPABASE INSERT ERROR:", error);
       setWebrtcStatus("ERROR Transmitting Offer: " + error.message);
    } else {
       console.log("Offer successfully inserted!");
    }
  };

  return (
    <div className="min-h-screen bg-gray-950 text-gray-100 font-sans p-6">
      <header className="flex flex-col md:flex-row justify-between items-start md:items-center mb-8 border-b border-gray-800 pb-6">
        <div>
          <h1 className="text-3xl font-bold tracking-tight text-white mb-2">Observer Dashboard</h1>
          <p className="text-sm text-gray-400">Continuous Probabilistic Fusion Telemetry</p>
        </div>
        <div className="mt-4 md:mt-0 flex items-center space-x-6 bg-gray-900 p-4 rounded-xl border border-gray-800">
          <div className="flex flex-col">
            <span className="text-xs text-gray-400 uppercase tracking-wider font-semibold">Predicted State</span>
            <span className={`text-xl font-bold flex items-center gap-2 ${liveStatus.includes("Offline") ? "text-red-400" : "text-emerald-400"}`}>
              {!liveStatus.includes("Offline") && <span className="w-2.5 h-2.5 rounded-full bg-emerald-400 animate-pulse"></span>}
              {liveStatus}
            </span>
          </div>
          <div className="w-px h-10 bg-gray-800"></div>
          <div className="flex flex-col">
            <span className="text-xs text-gray-400 uppercase tracking-wider font-semibold">Focus Score</span>
            <span className="text-2xl font-mono font-bold text-white">{currentScore}<span className="text-sm text-gray-500">/100</span></span>
          </div>
        </div>
      </header>

      <main className="grid grid-cols-1 lg:grid-cols-3 gap-6">
        {/* TELEMETRY CHART */}
        <section className="lg:col-span-2 bg-gray-900 border border-gray-800 rounded-2xl p-6 shadow-xl relative">
          {!isVideoActive && (
             <div className="mb-6 flex justify-between items-center">
               <h2 className="text-lg font-semibold text-white">Focus Score Trajectory</h2>
               <div className="flex space-x-2">
                 <span className="px-3 py-1 bg-gray-800 text-xs rounded-full border border-gray-700">Real-time Sync</span>
               </div>
             </div>
          )}
          
          {isVideoActive ? (
             <div className="h-[400px] w-full flex items-center justify-center text-gray-500 border-2 border-dashed border-gray-800 rounded-xl">
                 Telemetry overlay moved to Live Video Feed
             </div>
          ) : (
             <div className="h-[400px] w-full">
               <ResponsiveContainer width="100%" height="100%">
                 <AreaChart data={data} margin={{ top: 10, right: 10, left: -20, bottom: 0 }}>
                   <defs>
                     <linearGradient id="colorScore" x1="0" y1="0" x2="0" y2="1">
                       <stop offset="5%" stopColor="#3b82f6" stopOpacity={0.4} />
                       <stop offset="95%" stopColor="#3b82f6" stopOpacity={0} />
                     </linearGradient>
                   </defs>
                   <CartesianGrid strokeDasharray="3 3" stroke="#1f2937" vertical={false} />
                   <XAxis dataKey="time" stroke="#4b5563" tick={{fill: '#6b7280', fontSize: 12}} axisLine={false} tickLine={false} />
                   <YAxis stroke="#4b5563" tick={{fill: '#6b7280', fontSize: 12}} axisLine={false} tickLine={false} domain={[0, 100]} />
                   <Tooltip 
                     contentStyle={{ backgroundColor: '#111827', borderColor: '#374151', borderRadius: '0.5rem', color: '#f3f4f6' }}
                     itemStyle={{ color: '#60a5fa' }}
                   />
                   <Area 
                     type="monotone" 
                     dataKey="focus_score" 
                     stroke="#3b82f6" 
                     strokeWidth={3}
                     fillOpacity={1} 
                     fill="url(#colorScore)" 
                     activeDot={{ r: 6, fill: '#3b82f6', stroke: '#111827', strokeWidth: 2 }}
                   />
                 </AreaChart>
               </ResponsiveContainer>
             </div>
          )}
        </section>

        {/* WEBRTC TERMINAL */}
        <section className="bg-gray-900 border border-gray-800 rounded-2xl p-6 shadow-xl flex flex-col relative overflow-hidden">
          <div className="mb-4 flex justify-between items-center z-20">
            <h2 className="text-lg font-semibold text-white">WebRTC Terminal</h2>
            {isVideoActive && (
              <span className="flex h-2 w-2 relative">
                <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-400 opacity-75"></span>
                <span className="relative inline-flex rounded-full h-2 w-2 bg-red-500"></span>
              </span>
            )}
          </div>
          
          <div className="flex-1 bg-black rounded-xl border border-gray-800 relative overflow-hidden group flex items-center justify-center min-h-[300px]">
            {/* Live Video Element */}
            <video 
              ref={videoRef} 
              autoPlay 
              playsInline 
              muted 
              className={`absolute inset-0 w-full h-full object-cover ${!isVideoActive || webrtcStatus !== "" ? 'hidden' : ''}`}
            />
            
            {/* Overlay if waiting for stream */}
            {(!isVideoActive || webrtcStatus !== "") && (
              <>
                <div className="absolute inset-0 bg-gradient-to-t from-gray-900 to-transparent opacity-50 z-10"></div>
                <div className="text-center z-20 px-4">
                  <svg className="w-12 h-12 text-gray-600 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                    <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"></path>
                  </svg>
                  <p className="text-sm text-gray-500 mb-6 font-medium whitespace-pre-line">{webrtcStatus}</p>
                  
                  {!isVideoActive && (
                    <button 
                      onClick={handleLiveVerification}
                      className="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-semibold py-2.5 px-6 rounded-lg transition-colors duration-200 shadow-lg shadow-indigo-900/20 w-full focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 focus:ring-offset-gray-900"
                    >
                      Request Live Verification
                    </button>
                  )}
                </div>
              </>
            )}
            
            {/* Telemetry Overlay directly on video */}
            {(isVideoActive && webrtcStatus === "") && (
               <div className="absolute bottom-0 left-0 right-0 bg-gradient-to-t from-black/90 to-transparent pt-12 pb-4 px-4 z-30">
                  <div className="flex justify-between items-end">
                     <div>
                       <span className="text-[10px] text-gray-400 uppercase tracking-wider font-semibold block mb-1">Live State</span>
                       <span className="text-lg font-bold text-emerald-400 drop-shadow-md">{liveStatus}</span>
                     </div>
                     <div className="text-right">
                       <span className="text-[10px] text-gray-400 uppercase tracking-wider font-semibold block mb-1">Focus Score</span>
                       <span className="text-2xl font-mono font-bold text-white drop-shadow-md">{currentScore}</span>
                     </div>
                  </div>
               </div>
            )}
            
            {isVideoActive && webrtcStatus === "" && (
               <div className="absolute top-4 left-4 z-20">
                 <span className="bg-red-500/80 text-white text-[10px] px-2 py-1 rounded font-mono font-bold tracking-wider shadow-lg">LIVE OVERLAY</span>
               </div>
            )}
          </div>
        </section>
      </main>
    </div>
  );
}
