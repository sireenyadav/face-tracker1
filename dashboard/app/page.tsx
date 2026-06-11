"use client";

import React, { useState, useEffect } from "react";
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

  useEffect(() => {
    // 1. Tell Android we are watching (Triggers 1-second live stream mode)
    const notifyParentWatching = async () => {
      await supabase.from("device_status").upsert({ device_id: "global", is_watching: true });
    };
    notifyParentWatching();

    // 2. Load historical telemetry
    const fetchHistory = async () => {
      const { data: logs } = await supabase
        .from('telemetry_logs')
        .select('*')
        .order('timestamp', { ascending: false })
        .limit(60);
      
      if (logs) {
        const formatted = logs.reverse().map(log => ({
          time: new Date(log.timestamp).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' }),
          focus_score: log.focus_score
        }));
        setData(formatted);
        if (logs.length > 0) {
          setCurrentScore(logs[logs.length - 1].focus_score);
          setLiveStatus(logs[logs.length - 1].predicted_state);
        }
      }
    };
    fetchHistory();

    // 3. Subscribe to LIVE telemetry
    const channel = supabase
      .channel('schema-db-changes')
      .on(
        'postgres_changes',
        { event: 'INSERT', schema: 'public', table: 'telemetry_logs' },
        (payload) => {
          const newLog = payload.new;
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
      )
      .subscribe();

    // Cleanup: Turn off live stream mode
    return () => {
      supabase.from("device_status").upsert({ device_id: "global", is_watching: false });
      supabase.removeChannel(channel);
    };
  }, []);

  const handleLiveVerification = () => {
    alert("Live Verification Request Sent. Awaiting WebRTC Connection...");
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
            <span className="text-xl font-bold text-emerald-400 flex items-center gap-2">
              <span className="w-2.5 h-2.5 rounded-full bg-emerald-400 animate-pulse"></span>
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
        <section className="lg:col-span-2 bg-gray-900 border border-gray-800 rounded-2xl p-6 shadow-xl">
          <div className="mb-6 flex justify-between items-center">
            <h2 className="text-lg font-semibold text-white">Focus Score Trajectory</h2>
            <div className="flex space-x-2">
              <span className="px-3 py-1 bg-gray-800 text-xs rounded-full border border-gray-700">Real-time Sync</span>
            </div>
          </div>
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
        </section>

        <section className="bg-gray-900 border border-gray-800 rounded-2xl p-6 shadow-xl flex flex-col">
          <div className="mb-4 flex justify-between items-center">
            <h2 className="text-lg font-semibold text-white">WebRTC Terminal</h2>
            <span className="flex h-2 w-2 relative">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-red-400 opacity-75"></span>
              <span className="relative inline-flex rounded-full h-2 w-2 bg-red-500"></span>
            </span>
          </div>
          
          <div className="flex-1 bg-black rounded-xl border border-gray-800 relative overflow-hidden group flex items-center justify-center min-h-[300px]">
            <div className="absolute inset-0 bg-gradient-to-t from-gray-900 to-transparent opacity-50 z-10"></div>
            <div className="text-center z-20 px-4">
              <svg className="w-12 h-12 text-gray-600 mx-auto mb-4" fill="none" stroke="currentColor" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.5" d="M15 10l4.553-2.276A1 1 0 0121 8.618v6.764a1 1 0 01-1.447.894L15 14M5 18h8a2 2 0 002-2V8a2 2 0 00-2-2H5a2 2 0 00-2 2v8a2 2 0 002 2z"></path>
              </svg>
              <p className="text-sm text-gray-500 mb-6 font-medium">Video Feed Disconnected<br/>(Awaiting Phase 4 WebRTC Hookup)</p>
              
              <button 
                onClick={handleLiveVerification}
                className="bg-indigo-600 hover:bg-indigo-500 text-white text-sm font-semibold py-2.5 px-6 rounded-lg transition-colors duration-200 shadow-lg shadow-indigo-900/20 w-full focus:outline-none focus:ring-2 focus:ring-indigo-500 focus:ring-offset-2 focus:ring-offset-gray-900"
              >
                Request Live Verification
              </button>
            </div>
            
            <div className="absolute top-4 left-4 z-20">
              <span className="bg-black/60 text-white text-xs px-2 py-1 rounded font-mono border border-gray-700">REC</span>
            </div>
            <div className="absolute bottom-4 right-4 z-20">
              <span className="bg-black/60 text-white text-xs px-2 py-1 rounded font-mono border border-gray-700">720p 30fps</span>
            </div>
          </div>
        </section>
      </main>
    </div>
  );
}
