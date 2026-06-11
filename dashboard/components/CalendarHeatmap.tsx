"use client";

import React, { useState, useEffect } from "react";
// Assuming you have this fetch function defined in your lib/supabase-api.ts
// import { fetchDailyFocusSummaries } from "@/lib/supabase-api";

export interface DailySummary {
  calendar_date: string; // YYYY-MM-DD
  total_minutes_logged: number;
  overall_average_focus: number;
  physics_minutes: number;
  chemistry_minutes: number;
  maths_minutes: number;
  total_distraction_events: number;
  micro_sleep_count: number;
}

interface CalendarHeatmapProps {
  onDayClick: (date: string, summary: DailySummary | null) => void;
}

export default function CalendarHeatmap({ onDayClick }: CalendarHeatmapProps) {
  const [summaries, setSummaries] = useState<Record<string, DailySummary>>({});
  const [loading, setLoading] = useState(true);

  // Generate 52 weeks (364 days) of calendar data
  const generateCalendarDays = () => {
    const days = [];
    const today = new Date();
    // Start approx 1 year ago to build a 52-week grid ending today
    const startDate = new Date(today);
    startDate.setDate(today.getDate() - 364);

    for (let i = 0; i <= 364; i++) {
      const d = new Date(startDate);
      d.setDate(startDate.getDate() + i);
      days.push(d.toISOString().split("T")[0]); // YYYY-MM-DD
    }
    return days;
  };

  const calendarDays = generateCalendarDays();

  useEffect(() => {
    // Mocking the fetch call for demonstration purposes.
    // In production, you would fetch from the daily_focus_summaries table:
    // fetchDailyFocusSummaries().then(data => mapDataToDictionary(data));
    
    const mockData: Record<string, DailySummary> = {};
    const today = new Date();
    
    // Generate random mock data for the last 60 days to visualize the heatmap
    for (let i = 0; i < 60; i++) {
      const d = new Date(today);
      d.setDate(today.getDate() - i);
      const dateStr = d.toISOString().split("T")[0];
      
      const hasStudied = Math.random() > 0.3;
      if (hasStudied) {
        mockData[dateStr] = {
          calendar_date: dateStr,
          total_minutes_logged: Math.floor(Math.random() * 300) + 30, // 30 to 330 mins
          overall_average_focus: Math.floor(Math.random() * 40) + 60, // 60 to 100 score
          physics_minutes: Math.floor(Math.random() * 100),
          chemistry_minutes: Math.floor(Math.random() * 100),
          maths_minutes: Math.floor(Math.random() * 100),
          total_distraction_events: Math.floor(Math.random() * 20),
          micro_sleep_count: Math.floor(Math.random() * 5),
        };
      }
    }
    
    setSummaries(mockData);
    setLoading(false);
  }, []);

  const getHeatmapColor = (summary?: DailySummary) => {
    if (!summary || summary.total_minutes_logged === 0) {
      return "bg-gray-800 border-gray-700/50 hover:border-gray-500"; // Empty / Transparent / Gray
    }

    // Determine intensity based on total minutes AND focus score
    const volume = summary.total_minutes_logged;
    const focus = summary.overall_average_focus;

    if (focus >= 85 && volume >= 120) {
      return "bg-emerald-500 border-emerald-400 hover:border-white shadow-[0_0_10px_rgba(16,185,129,0.5)]"; // Dark Emerald Green = High focus & high volume
    } else if (focus >= 75 && volume >= 60) {
      return "bg-emerald-600 border-emerald-500 hover:border-white"; // Moderate
    } else if (focus >= 60 && volume > 0) {
      return "bg-green-800 border-green-700 hover:border-white"; // Light Green = Low focus / Low volume
    } else {
      return "bg-green-900 border-green-800 hover:border-white"; // Very light activity
    }
  };

  if (loading) {
    return <div className="animate-pulse bg-gray-900 rounded-xl h-48 w-full border border-gray-800"></div>;
  }

  // Organize days into weeks for column-based rendering (GitHub style)
  // Grid: 7 rows (days of week), 52 columns (weeks)
  const weeks = [];
  for (let i = 0; i < calendarDays.length; i += 7) {
    weeks.push(calendarDays.slice(i, i + 7));
  }

  return (
    <div className="bg-gray-900 border border-gray-800 rounded-2xl p-6 shadow-xl w-full overflow-x-auto">
      <div className="flex justify-between items-end mb-4">
        <div>
          <h2 className="text-lg font-semibold text-white">Longitudinal Focus Heatmap</h2>
          <p className="text-xs text-gray-400 mt-1">Permanent Ledger Activity Overview</p>
        </div>
        <div className="flex items-center space-x-2 text-xs text-gray-400">
          <span>Less</span>
          <div className="w-3 h-3 rounded-sm bg-gray-800 border border-gray-700/50"></div>
          <div className="w-3 h-3 rounded-sm bg-green-900 border border-green-800"></div>
          <div className="w-3 h-3 rounded-sm bg-green-800 border border-green-700"></div>
          <div className="w-3 h-3 rounded-sm bg-emerald-600 border border-emerald-500"></div>
          <div className="w-3 h-3 rounded-sm bg-emerald-500 border border-emerald-400 shadow-[0_0_8px_rgba(16,185,129,0.4)]"></div>
          <span>More</span>
        </div>
      </div>

      <div className="flex select-none">
        {/* Days of week labels */}
        <div className="flex flex-col space-y-1.5 mr-2 mt-6 text-[10px] text-gray-500 font-medium tracking-wide">
          <div className="h-3"></div>
          <div className="h-3 leading-3">Mon</div>
          <div className="h-3"></div>
          <div className="h-3 leading-3">Wed</div>
          <div className="h-3"></div>
          <div className="h-3 leading-3">Fri</div>
          <div className="h-3"></div>
        </div>

        {/* Heatmap Grid */}
        <div className="flex space-x-1.5">
          {weeks.map((week, weekIndex) => (
            <div key={`week-${weekIndex}`} className="flex flex-col space-y-1.5">
              {/* Optional Month Labels could go here conditionally based on the first day of the week */}
              {weekIndex % 4 === 0 ? (
                <div className="text-[10px] text-gray-500 font-medium h-4">
                  {new Date(week[0]).toLocaleString('default', { month: 'short' })}
                </div>
              ) : (
                <div className="h-4"></div>
              )}
              
              {week.map((dayStr) => {
                const summary = summaries[dayStr];
                return (
                  <div
                    key={dayStr}
                    onClick={() => onDayClick(dayStr, summary || null)}
                    className={`w-3 h-3 rounded-sm border cursor-pointer transition-all duration-200 ${getHeatmapColor(summary)}`}
                    title={`${dayStr}: ${summary ? `${summary.total_minutes_logged} mins | ${summary.overall_average_focus} focus` : 'No Activity'}`}
                  ></div>
                );
              })}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
