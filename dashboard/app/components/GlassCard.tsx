import React from 'react';

interface GlassCardProps {
  children: React.ReactNode;
  className?: string;
  style?: React.CSSProperties;
}

export function GlassCard({ children, className = '', style = {} }: GlassCardProps) {
  return (
    <div 
      className={`relative overflow-hidden rounded-2xl backdrop-blur-2xl ${className}`}
      style={{
        background: 'linear-gradient(135deg, rgba(255,255,255,0.1) 0%, rgba(255,255,255,0.02) 100%)',
        border: '1px solid rgba(255, 255, 255, 0.1)',
        borderTop: '1px solid rgba(255, 255, 255, 0.3)',
        borderLeft: '1px solid rgba(255, 255, 255, 0.3)',
        boxShadow: '0 8px 32px 0 rgba(0, 0, 0, 0.2)',
        ...style
      }}
    >
      <div className="absolute inset-0 z-0 bg-white opacity-[0.02] mix-blend-overlay"></div>
      <div className="relative z-10 w-full h-full p-6">
        {children}
      </div>
    </div>
  );
}
