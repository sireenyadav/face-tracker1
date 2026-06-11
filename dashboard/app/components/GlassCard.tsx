import React from 'react';

interface GlassCardProps {
  children: React.ReactNode;
  className?: string;
  style?: React.CSSProperties;
  variant?: 'light' | 'dark' | 'transparent';
}

export function GlassCard({ children, className = '', style = {}, variant = 'light' }: GlassCardProps) {
  const getBackground = () => {
    switch(variant) {
      case 'dark':
        return 'linear-gradient(135deg, rgba(15, 23, 42, 0.9) 0%, rgba(15, 23, 42, 0.7) 100%)';
      case 'transparent':
        return 'transparent';
      default:
        return 'linear-gradient(135deg, rgba(255,255,255,0.7) 0%, rgba(255,255,255,0.4) 100%)';
    }
  };

  const getBorder = () => {
    if (variant === 'dark') return '1px solid rgba(255, 255, 255, 0.1)';
    if (variant === 'transparent') return 'none';
    return '1px solid rgba(255, 255, 255, 0.6)';
  };

  const getBoxShadow = () => {
    if (variant === 'dark' || variant === 'transparent') return '0 8px 32px 0 rgba(0, 0, 0, 0.3)';
    return '0 8px 32px 0 rgba(31, 38, 135, 0.1)';
  };

  return (
    <div 
      className={`relative overflow-hidden rounded-3xl backdrop-blur-2xl ${className}`}
      style={{
        background: getBackground(),
        border: getBorder(),
        boxShadow: getBoxShadow(),
        ...style
      }}
    >
      <div className="relative z-10 w-full h-full">
        {children}
      </div>
    </div>
  );
}
