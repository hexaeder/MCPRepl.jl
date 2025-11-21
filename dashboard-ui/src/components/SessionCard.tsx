import React from 'react';
import { Session } from '../types';
import './SessionCard.css';
import { HeartbeatChart } from './HeartbeatChart';

interface SessionCardProps {
    session: Session;
    isSelected: boolean;
    onClick: () => void;
    onShutdown?: (sessionId: string) => void;
    onRestart?: (sessionId: string) => void;
}

export const SessionCard: React.FC<SessionCardProps> = ({ session, isSelected, onClick, onShutdown, onRestart }) => {
    const getStatusColor = (status: string) => {
        switch (status) {
            case 'ready': return '#10b981';       // Green
            case 'disconnected': return '#ffa726'; // Orange
            case 'reconnecting': return '#42a5f5'; // Blue
            case 'stopped': return '#ef5350';      // Red
            case 'busy': return '#f59e0b';        // Amber
            case 'error': return '#ef4444';       // Red
            default: return '#64748b';            // Gray
        }
    };

    return (
        <div
            className={`session-card ${isSelected ? 'selected' : ''}`}
            onClick={onClick}
            title="Click to view logs"
        >
            <div className="session-header">
                <span className="session-id">{session.id}</span>
            </div>

            <div className="status-line">
                <span
                    className="status-badge"
                    style={{ backgroundColor: getStatusColor(session.status) }}
                >
                    {session.status}
                </span>
                <div className="session-controls">
                    {onRestart && (
                        <button
                            className="restart-btn"
                            onClick={(e) => {
                                e.stopPropagation();
                                onRestart(session.id);
                            }}
                            title="Restart this session"
                        >
                            🔄
                        </button>
                    )}
                    {onShutdown && (
                        <button
                            className="shutdown-btn"
                            onClick={(e) => {
                                e.stopPropagation();
                                onShutdown(session.id);
                            }}
                            title="Shutdown this session"
                        >
                            ⏻
                        </button>
                    )}
                </div>
            </div>

            <div className="session-meta">
                <div className="meta-item">
                    <span className="meta-label">Port:</span>
                    <span className="meta-value">{session.port}</span>
                </div>
                <div className="meta-item">
                    <span className="meta-label">PID:</span>
                    <span className="meta-value">{session.pid}</span>
                </div>
            </div>

            <div className="heartbeat-container">
                <HeartbeatChart sessionId={session.id} />
            </div>
        </div>
    );
};
