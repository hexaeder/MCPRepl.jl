import React, { useEffect, useState } from 'react';
import { fetchAgents, fetchEvents } from './api';
import { Agent, AgentEvent } from './types';
import { AgentCard } from './components/AgentCard';
import { MetricCard } from './components/MetricCard';
import { JsonViewer } from '@textea/json-viewer';
import './App.css';

export const App: React.FC = () => {
    const [agents, setAgents] = useState<Record<string, Agent>>({});
    const [events, setEvents] = useState<AgentEvent[]>([]);
    const [selectedAgent, setSelectedAgent] = useState<string | null>(null);
    const [activeTab, setActiveTab] = useState<'overview' | 'events' | 'terminal'>('overview');
    const [eventFilter, setEventFilter] = useState<string>('interesting');
    const [selectedEvent, setSelectedEvent] = useState<AgentEvent | null>(null);

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
        const interval = setInterval(loadData, 500);
        return () => clearInterval(interval);
    }, []);

    const agentCount = Object.keys(agents).length;
    const eventCount = events.filter(e => e.type !== 'HEARTBEAT').length;

    return (
        <div className="app">
            <header className="header">
                <div className="header-brand">
                    <div className="logo">⚡</div>
                    <h1>MCPRepl Dashboard</h1>
                </div>
                <div className="header-stats">
                    <div className="stat">
                        <span className="stat-label">AGENTS</span>
                        <span className="stat-value" id="header-agents">{agentCount}</span>
                    </div>
                    <div className="stat">
                        <span className="stat-label">EVENTS</span>
                        <span className="stat-value" id="header-events">{eventCount}</span>
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
                                <div className="metrics-grid">
                                    <MetricCard
                                        icon="👥"
                                        label="Total Agents"
                                        value={agentCount}
                                    />
                                    <MetricCard
                                        icon="⚡"
                                        label="Active Agents"
                                        value={Object.values(agents).filter(a => a.status === 'ready').length}
                                    />
                                    <MetricCard
                                        icon="📊"
                                        label="Total Events"
                                        value={eventCount}
                                    />
                                    <MetricCard
                                        icon="🔥"
                                        label="Events/min"
                                        value={events.filter(e => {
                                            const eventTime = new Date(e.timestamp);
                                            const now = new Date();
                                            return (now.getTime() - eventTime.getTime()) < 60000;
                                        }).length}
                                    />
                                    <MetricCard
                                        icon="⚠️"
                                        label="Errors"
                                        value={events.filter(e => e.type === 'ERROR').length}
                                        valueColor="#ef4444"
                                    />
                                    <MetricCard
                                        icon="🔧"
                                        label="Tool Calls"
                                        value={events.filter(e => e.type === 'TOOL_CALL').length}
                                        valueColor="#00d9ff"
                                    />
                                </div>
                            </div>
                        )}

                        {activeTab === 'events' && (
                            <div className="view active" id="events-view">
                                <div className="events-header">
                                    <h2>Recent Events</h2>
                                    <div className="event-filters">
                                        {['interesting', 'TOOL_CALL', 'CODE_EXECUTION', 'OUTPUT', 'ERROR', 'all'].map(filter => (
                                            <button
                                                key={filter}
                                                className={`filter-btn ${eventFilter === filter ? 'active' : ''}`}
                                                onClick={() => setEventFilter(filter)}
                                            >
                                                {filter === 'interesting' ? 'Interesting' : filter === 'all' ? 'All' : filter.replace('_', ' ')}
                                            </button>
                                        ))}
                                    </div>
                                </div>
                                <div id="event-list" className="event-list">
                                    {events
                                        .filter(e => {
                                            if (eventFilter === 'interesting') return e.type !== 'HEARTBEAT';
                                            if (eventFilter === 'all') return true;
                                            return e.type === eventFilter;
                                        })
                                        .slice(0, 100)
                                        .reverse()
                                        .map((event, idx) => (
                                            <div key={idx} className={`event event-${event.type.toLowerCase()}`} onClick={() => setSelectedEvent(event)}>
                                                <div className="event-type">{event.type}</div>
                                                <div className="event-header">
                                                    <span className="event-agent">{event.id}</span>
                                                    <span className="event-time">{event.timestamp}</span>
                                                    {event.duration_ms && (
                                                        <span className="event-duration">{event.duration_ms.toFixed(2)}ms</span>
                                                    )}
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
                                <h2>Agent Log: {selectedAgent || 'Select an agent'}</h2>
                                <div className="terminal">
                                    <div className="terminal-output">
                                        {selectedAgent ? (
                                            events
                                                .filter(e => e.id === selectedAgent)
                                                .reverse()
                                                .slice(0, 50)
                                                .map((event, idx) => (
                                                    <div key={idx} className="log-entry">
                                                        <span className="log-time">[{event.timestamp}]</span>
                                                        <span className={`log-type log-${event.type.toLowerCase()}`}>{event.type}</span>
                                                        <span className="log-data">{JSON.stringify(event.data)}</span>
                                                        {event.duration_ms && <span className="log-duration">({event.duration_ms.toFixed(2)}ms)</span>}
                                                    </div>
                                                ))
                                        ) : (
                                            <div className="log-placeholder">← Select an agent from the sidebar to view its log</div>
                                        )}
                                    </div>
                                </div>
                            </div>
                        )}
                    </div>
                </main>
            </div>

            {selectedEvent && (
                <div className="modal-overlay" onClick={() => setSelectedEvent(null)}>
                    <div className="modal" onClick={(e) => e.stopPropagation()}>
                        <div className="modal-header">
                            <h2>Event Details</h2>
                            <button className="modal-close" onClick={() => setSelectedEvent(null)}>×</button>
                        </div>
                        <div className="modal-content">
                            <div className="detail-row">
                                <span className="detail-label">Type:</span>
                                <span className={`detail-value event-badge event-${selectedEvent.type.toLowerCase()}`}>{selectedEvent.type}</span>
                            </div>
                            <div className="detail-row">
                                <span className="detail-label">Agent ID:</span>
                                <span className="detail-value">{selectedEvent.id}</span>
                            </div>
                            <div className="detail-row">
                                <span className="detail-label">Timestamp:</span>
                                <span className="detail-value">{selectedEvent.timestamp}</span>
                            </div>
                            {selectedEvent.duration_ms && (
                                <div className="detail-row">
                                    <span className="detail-label">Duration:</span>
                                    <span className="detail-value">{selectedEvent.duration_ms.toFixed(2)} ms</span>
                                </div>
                            )}
                            {selectedEvent.data.tool && (
                                <div className="detail-row">
                                    <span className="detail-label">Tool:</span>
                                    <span className="detail-value">{selectedEvent.data.tool}</span>
                                </div>
                            )}
                            {selectedEvent.data.arguments && Object.keys(selectedEvent.data.arguments).length > 0 && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Arguments:</span>
                                    <div className="detail-value json-tree">
                                        <JsonViewer
                                            value={selectedEvent.data.arguments}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={false}
                                            rootName="arguments"
                                        />
                                    </div>
                                </div>
                            )}
                            {selectedEvent.data.result && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Result:</span>
                                    <div className="detail-value json-tree">
                                        <JsonViewer
                                            value={selectedEvent.data.result}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={false}
                                            rootName="result"
                                        />
                                    </div>
                                </div>
                            )}
                            {selectedEvent.data.error && (
                                <div className="detail-row detail-data">
                                    <span className="detail-label">Error:</span>
                                    <div className="detail-value json-tree error-tree">
                                        <JsonViewer
                                            value={selectedEvent.data.error}
                                            theme="dark"
                                            defaultInspectDepth={2}
                                            displayDataTypes={false}
                                            rootName="error"
                                        />
                                    </div>
                                </div>
                            )}
                            <div className="detail-row detail-data">
                                <span className="detail-label">Raw Data:</span>
                                <div className="detail-value json-tree">
                                    <JsonViewer
                                        value={selectedEvent.data}
                                        theme="dark"
                                        defaultInspectDepth={1}
                                        displayDataTypes={false}
                                        rootName="data"
                                    />
                                </div>
                            </div>
                        </div>
                    </div>
                </div>
            )}
        </div>
    );
};
