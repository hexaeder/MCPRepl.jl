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
      case 'ready': return '#10b981';
      case 'busy': return '#f59e0b';
      case 'error': return '#ef4444';
      case 'stopped': return '#64748b';
      default: return '#64748b';
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
