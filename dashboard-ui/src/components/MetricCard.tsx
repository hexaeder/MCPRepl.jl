import React from 'react';
import './MetricCard.css';

interface MetricCardProps {
    icon: string;
    label: string;
    value: number;
    valueColor?: string;
    trend?: number; // positive or negative change
    onClick?: () => void;
}

export const MetricCard: React.FC<MetricCardProps> = ({
    icon,
    label,
    value,
    valueColor = '#7dd3fc',
    trend,
    onClick
}) => {
    return (
        <div
            className={`metric-card ${onClick ? 'clickable' : ''}`}
            onClick={onClick}
            style={{ cursor: onClick ? 'pointer' : 'default' }}
        >
            <div className="metric-icon">{icon}</div>
            <div className="metric-content">
                <div className="metric-label">{label}</div>
                <div className="metric-value" style={{ color: valueColor }}>
                    {value.toLocaleString()}
                </div>
                {trend !== undefined && trend !== 0 && (
                    <div className={`metric-trend ${trend > 0 ? 'positive' : 'negative'}`}>
                        {trend > 0 ? '↑' : '↓'} {Math.abs(trend)}
                    </div>
                )}
            </div>
        </div>
    );
};
