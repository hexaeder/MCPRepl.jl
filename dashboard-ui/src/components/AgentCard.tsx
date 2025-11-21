import React from 'react';
import { Agent } from '../types';
import './AgentCard.css';
import { HeartbeatChart } from './HeartbeatChart';

interface AgentCardProps {
    agent: Agent;
    isSelected: boolean;
    onClick: () => void;
}

export const AgentCard: React.FC<AgentCardProps> = ({ agent, isSelected, onClick }) => {
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
            className={`agent-card ${isSelected ? 'selected' : ''}`}
            onClick={onClick}
        >
            <div className="agent-header">
                <span className="agent-id">{agent.id}</span>
                <span
                    className="status-badge"
                    style={{ backgroundColor: getStatusColor(agent.status) }}
                >
                    {agent.status}
                </span>
            </div>

            <div className="agent-meta">
                <div className="meta-item">
                    <span className="meta-label">Port:</span>
                    <span className="meta-value">{agent.port}</span>
                </div>
                <div className="meta-item">
                    <span className="meta-label">PID:</span>
                    <span className="meta-value">{agent.pid}</span>
                </div>
            </div>

            <div className="heartbeat-container">
                <HeartbeatChart agentId={agent.id} />
            </div>
        </div>
    );
};
