import React, { useEffect, useState } from 'react';
import { fetchAgents, fetchEvents } from './api';
import { Agent, AgentEvent } from './types';
import { AgentCard } from './components/AgentCard';
import './App.css';

export const App: React.FC = () => {
  const [agents, setAgents] = useState<Record<string, Agent>>({});
  const [events, setEvents] = useState<AgentEvent[]>([]);
  const [selectedAgent, setSelectedAgent] = useState<string | null>(null);
  const [activeTab, setActiveTab] = useState<'overview' | 'events' | 'terminal'>('overview');

  useEffect(() => {
    const loadData = async () => {
      try {
        const [agentsData, eventsData] = await Promise.all([
          fetchAgents(),
          fetchEvents(undefined, 100)
        ]);
        setAgents(agentsData);
        setEvents(eventsData);
      } catch (error) {
        console.error('Failed to load data:', error);
      }
    };

    loadData();
    const interval = setInterval(loadData, 1000);
    return () => clearInterval(interval);
  }, []);

  const agentCount = Object.keys(agents).length;
  const eventCount = events.length;

  return (
    <div className="app">
      <header className="header">
        <div className="header-brand">
          <div className="logo">⚡</div>
          <h1>MCPRepl Dashboard</h1>
        </div>
        <div className="header-stats">
          <div className="stat">
            <span className="stat-label">Agents</span>
            <span className="stat-value" id="header-agents">{agentCount}</span>
          </div>
          <div className="stat">
            <span className="stat-label">Events</span>
            <span className="stat-value" id="header-events">{eventCount}</span>
          </div>
          <div className="status-indicator">
            <div className="pulse"></div>
            <div className="ring"></div>
          </div>
        </div>
      </header>

      <div className="main-container">
        <aside className="sidebar">
          <div className="sidebar-header">
            <h2>Agents</h2>
            <span className="agent-count">{agentCount}</span>
          </div>
          <div className="agent-list">
            {Object.entries(agents).map(([id, agent]) => (
              <AgentCard
                key={id}
                agent={agent}
                isSelected={selectedAgent === id}
                onClick={() => setSelectedAgent(id)}
              />
            ))}
          </div>
        </aside>

        <main className="content">
          <div className="tabs">
            <button
              className={`tab ${activeTab === 'overview' ? 'active' : ''}`}
              onClick={() => setActiveTab('overview')}
            >
              Overview
            </button>
            <button
              className={`tab ${activeTab === 'events' ? 'active' : ''}`}
              onClick={() => setActiveTab('events')}
            >
              Events
            </button>
            <button
              className={`tab ${activeTab === 'terminal' ? 'active' : ''}`}
              onClick={() => setActiveTab('terminal')}
            >
              Terminal
            </button>
          </div>

          <div className="view-container">
            {activeTab === 'overview' && (
              <div className="view active" id="overview-view">
                <h2>System Overview</h2>
                <div id="overview-metrics" className="metrics-grid">
                  {/* Metrics will be rendered here */}
                </div>
              </div>
            )}

            {activeTab === 'events' && (
              <div className="view active" id="events-view">
                <h2>Recent Events</h2>
                <div id="event-list" className="event-list">
                  {events.slice(0, 50).map((event, idx) => (
                    <div key={idx} className={`event event-${event.event_type.toLowerCase()}`}>
                      <div className="event-type">{event.event_type}</div>
                      <div className="event-header">
                        <span className="event-agent">{event.id}</span>
                        <span className="event-time">{event.timestamp}</span>
                      </div>
                      <div className="event-body">
                        {event.data.description || event.data.tool || event.data.method || JSON.stringify(event.data)}
                      </div>
                    </div>
                  ))}
                </div>
              </div>
            )}

            {activeTab === 'terminal' && (
              <div className="view active" id="terminal-view">
                <h2>Terminal Output</h2>
                <div className="terminal">
                  <div id="terminal-output" className="terminal-output">
                    {events.slice(-20).map((event, idx) => {
                      const typeColor: Record<string, string> = {
                        'ERROR': '#ff4444',
                        'TOOL_CALL': '#00d9ff',
                        'CODE_EXECUTION': '#7c3aed',
                        'OUTPUT': '#4ade80',
                        'HEARTBEAT': '#888',
                        'AGENT_START': '#4ade80',
                        'AGENT_STOP': '#ff4444'
                      };
                      const color = typeColor[event.event_type] || '#888';
                      
                      return (
                        <div key={idx}>
                          <span style={{ color }}>[{event.timestamp}]</span>{' '}
                          <span style={{ color: '#00d9ff' }}>{event.id}</span>{' '}
                          <span style={{ color }}>{event.event_type}</span>:{' '}
                          {event.data.description || event.data.tool || event.data.method || JSON.stringify(event.data)}
                        </div>
                      );
                    })}
                  </div>
                </div>
              </div>
            )}
          </div>
        </main>
      </div>
    </div>
  );
};
