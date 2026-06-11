"use client";

import React, { useMemo } from "react";

interface FocusRingGaugeProps {
  score: number;       // 0–100
  state?: string;      // label shown below the number
  size?: number;       // px, default 180
  strokeWidth?: number; // default 14
}

function getColor(score: number): { stroke: string; glow: string } {
  if (score >= 80) {
    return { stroke: "#10b981", glow: "rgba(16,185,129,0.55)" };
  } else if (score >= 50) {
    return { stroke: "#f59e0b", glow: "rgba(245,158,11,0.55)" };
  } else {
    return { stroke: "#ef4444", glow: "rgba(239,68,68,0.55)" };
  }
}

export const FocusRingGauge: React.FC<FocusRingGaugeProps> = ({
  score,
  state,
  size = 180,
  strokeWidth = 14,
}) => {
  const clampedScore = Math.max(0, Math.min(100, score));
  const { stroke, glow } = getColor(clampedScore);

  // SVG geometry
  const radius = (size - strokeWidth) / 2;
  const cx = size / 2;
  const cy = size / 2;
  const circumference = 2 * Math.PI * radius;
  const offset = circumference - (clampedScore / 100) * circumference;

  // Pulse ring: slightly larger radius
  const pulseRadius = radius + strokeWidth * 0.9;
  const showPulse = clampedScore > 75;

  // Unique filter ID to avoid SVG conflicts when multiple gauges render
  const filterId = useMemo(
    () => `glow-${Math.random().toString(36).slice(2, 8)}`,
    []
  );
  const pulseAnimId = useMemo(
    () => `pulse-${Math.random().toString(36).slice(2, 8)}`,
    []
  );

  return (
    <div
      className="relative flex flex-col items-center justify-center select-none"
      style={{ width: size, height: size }}
    >
      <svg
        width={size}
        height={size}
        viewBox={`0 0 ${size} ${size}`}
        style={{ overflow: "visible" }}
      >
        <defs>
          {/* Glow filter */}
          <filter id={filterId} x="-50%" y="-50%" width="200%" height="200%">
            <feGaussianBlur stdDeviation="4" result="coloredBlur" />
            <feMerge>
              <feMergeNode in="coloredBlur" />
              <feMergeNode in="SourceGraphic" />
            </feMerge>
          </filter>

          {/* Pulse expand keyframes */}
          <style>{`
            @keyframes ${pulseAnimId} {
              0%   { r: ${pulseRadius}px; opacity: 0.7; stroke-width: 3px; }
              70%  { r: ${pulseRadius + 18}px; opacity: 0.15; stroke-width: 1px; }
              100% { r: ${pulseRadius + 24}px; opacity: 0; stroke-width: 0px; }
            }
            .pulse-ring-${pulseAnimId} {
              animation: ${pulseAnimId} 2s ease-out infinite;
              transform-origin: ${cx}px ${cy}px;
            }
          `}</style>
        </defs>

        {/* Track ring (background) */}
        <circle
          cx={cx}
          cy={cy}
          r={radius}
          fill="none"
          stroke="rgba(255,255,255,0.08)"
          strokeWidth={strokeWidth}
        />

        {/* Pulse ring (only when score > 75) */}
        {showPulse && (
          <circle
            cx={cx}
            cy={cy}
            r={pulseRadius}
            fill="none"
            stroke={stroke}
            strokeWidth={3}
            className={`pulse-ring-${pulseAnimId}`}
            style={{ opacity: 0.7 }}
          />
        )}

        {/* Score arc */}
        <circle
          cx={cx}
          cy={cy}
          r={radius}
          fill="none"
          stroke={stroke}
          strokeWidth={strokeWidth}
          strokeLinecap="round"
          strokeDasharray={circumference}
          strokeDashoffset={offset}
          transform={`rotate(-90 ${cx} ${cy})`}
          filter={`url(#${filterId})`}
          style={{
            transition: "stroke-dashoffset 0.7s cubic-bezier(0.4,0,0.2,1), stroke 0.7s ease",
            filter: `url(#${filterId}) drop-shadow(0 0 8px ${glow})`,
          }}
        />
      </svg>

      {/* Center text overlay (positioned absolutely over SVG) */}
      <div
        className="absolute inset-0 flex flex-col items-center justify-center pointer-events-none"
        style={{ top: 0, left: 0 }}
      >
        <span
          className="font-bold leading-none"
          style={{
            fontFamily: '"Playfair Display", serif',
            fontSize: size * 0.28,
            color: stroke,
            textShadow: `0 0 20px ${glow}`,
            transition: "color 0.7s ease, text-shadow 0.7s ease",
          }}
        >
          {clampedScore}
        </span>
        <span
          className="font-semibold uppercase tracking-widest mt-1 text-center px-2"
          style={{
            fontSize: size * 0.07,
            color: "rgba(255,255,255,0.5)",
            lineHeight: 1.2,
            maxWidth: size * 0.7,
          }}
        >
          {state ?? "—"}
        </span>
      </div>
    </div>
  );
};

export default FocusRingGauge;
