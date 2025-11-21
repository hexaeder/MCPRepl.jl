import React, { useEffect, useState, useRef } from 'react';
import { fetchAgents, fetchEvents, subscribeToEvents } from './api';
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
    const terminalRef = useRef<HTMLDivElement>(null);
    const terminalBottomRef = useRef<HTMLDivElement>(null);
    const [isNearBottom, setIsNearBottom] = useState(true);
    const [terminalSearch, setTerminalSearch] = useState('');

    useEffect(() => {
        const loadInitialData = async () => {
            try {
                const [agentsData, eventsData] = await Promise.all([
                    fetchAgents(),
                    fetchEvents(undefined, 1000)
                ]);
                setAgents(agentsData);
                setEvents(eventsData);
            } catch (error) {
                console.error('Failed to load initial data:', error);
            }
        };

        loadInitialData();
        
        // Poll for agents updates (less frequently)
        const agentsInterval = setInterval(async () => {
            try {
                const agentsData = await fetchAgents();
                setAgents(agentsData);
            } catch (error) {
                console.error('Failed to refresh agents:', error);
            }
        }, 2000);

        // Subscribe to event stream
        const unsubscribe = subscribeToEvents((newEvent) => {
            setEvents(prev => {
                // Check if event already exists
                const exists = prev.some(e => 
                    e.timestamp === newEvent.timestamp && 
                    e.id === newEvent.id && 
                    e.type === newEvent.type
                );
                if (exists) return prev;
                
                // Add new event and keep last 1000
                return [...prev, newEvent].slice(-1000);
            });
        });

        return () => {
            clearInterval(agentsInterval);
            unsubscribe();
        };
    }, []);

    // Autoscroll to bottom when new events arrive (only if near bottom)
    useEffect(() => {
        if (activeTab === 'terminal' && terminalBottomRef.current && isNearBottom) {
            const timer = setTimeout(() => {
                terminalBottomRef.current?.scrollIntoView({ behavior: 'auto', block: 'end' });
            }, 50);
            return () => clearTimeout(timer);
        }
    }, [events, isNearBottom]);

    // Track scroll position to detect if user is near bottom
    const handleTerminalScroll = () => {
        if (terminalRef.current) {
            const { scrollTop, scrollHeight, clientHeight } = terminalRef.current;
            const threshold = 100; // pixels from bottom
            const nearBottom = scrollHeight - scrollTop - clientHeight <= threshold;
            setIsNearBottom(nearBottom);
        }
    };

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
                                        valueColor="#7dd3fc"
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
                            <div className="view active terminal-view" id="terminal-view">
                                <div className="terminal-controls">
                                    <input 
                                        type="text" 
                                        placeholder="Search terminal..." 
                                        className="terminal-search"
                                        onChange={(e) => setTerminalSearch(e.target.value)}
                                    />
                                    <button onClick={() => terminalRef.current?.scrollTo({ top: 0, behavior: 'smooth' })} className="terminal-control-btn">↑ Top</button>
                                    <button onClick={() => terminalBottomRef.current?.scrollIntoView({ behavior: 'smooth', block: 'end' })} className="terminal-control-btn">↓ Bottom</button>
                                </div>
                                <div className="terminal">
                                    <div className="terminal-output" ref={terminalRef} onScroll={handleTerminalScroll}>
                                        {selectedAgent ? (
                                            events
                                                .filter(e => e.id === selectedAgent && e.type !== 'HEARTBEAT')
                                                .slice(-1000)
                                                .filter(event => {
                                                    if (!terminalSearch) return true;
                                                    const searchLower = terminalSearch.toLowerCase();
                                                    const eventStr = JSON.stringify(event.data).toLowerCase();
                                                    return eventStr.includes(searchLower);
                                                })
                                                .map((event, idx) => {
                                                    const renderEvent = () => {
                                                        switch (event.type) {
                                                            case 'TOOL_CALL':
                                                                // For ex tool, show the actual Julia expression
                                                                if (event.data.tool === 'ex') {
                                                                    const expr = event.data.arguments?.e || '';
                                                                    return (
                                                                        <>
                                                                            <span className="terminal-prompt">julia&gt;</span>
                                                                            <span className="terminal-code">{expr}</span>
                                                                        </>
                                                                    );
                                                                }
                                                                // For other tools, show tool name and args
                                                                return (
                                                                    <>
                                                                        <span className="terminal-prompt">julia&gt;</span>
                                                                        <span className="terminal-tool">{event.data.tool}</span>
                                                                        <span className="terminal-args">({JSON.stringify(event.data.arguments).slice(0, 60)}...)</span>
                                                                    </>
                                                                );
                                                            case 'CODE_EXECUTION':
                                                                return (
                                                                    <>
                                                                        <span className="terminal-prompt">julia&gt;</span>
                                                                        <span className="terminal-method">{event.data.method}</span>
                                                                    </>
                                                                );
                                                            case 'OUTPUT':
                                                                // Extract the actual content from the result
                                                                let output = '';
                                                                if (event.data.result?.content) {
                                                                    // MCP result format with content array
                                                                    const contents = event.data.result.content;
                                                                    if (Array.isArray(contents)) {
                                                                        output = contents.map((c: any) => c.text || '').join('\n');
                                                                    }
                                                                } else if (event.data.result) {
                                                                    output = typeof event.data.result === 'string' 
                                                                        ? event.data.result 
                                                                        : JSON.stringify(event.data.result, null, 2);
                                                                }
                                                                
                                                                return (
                                                                    <>
                                                                        <span className="terminal-output-text">{output || '(no output)'}</span>
                                                                        {event.duration_ms && <span className="terminal-duration"> [{event.duration_ms.toFixed(1)}ms]</span>}
                                                                    </>
                                                                );
                                                            case 'ERROR':
                                                                return (
                                                                    <>
                                                                        <span className="terminal-error">ERROR: {event.data.message || JSON.stringify(event.data)}</span>
                                                                    </>
                                                                );
                                                            case 'AGENT_START':
                                                                return <span className="terminal-info">→ Agent started on port {event.data.port}</span>;
                                                            case 'AGENT_STOP':
                                                                return <span className="terminal-info">→ Agent stopped</span>;
                                                            default:
                                                                return <span className="terminal-default">{JSON.stringify(event.data)}</span>;
                                                        }
                                                    };
                                                    
                                                    return (
                                                        <div key={idx} className={`terminal-line terminal-${event.type.toLowerCase()}`}>
                                                            <span className="terminal-time">{event.timestamp.split(' ')[1]}</span>
                                                            {renderEvent()}
                                                        </div>
                                                    );
                                                })
                                        ) : (
                                            <div className="log-placeholder">← Select an agent from the sidebar to view its REPL activity</div>
                                        )}
                                        <div ref={terminalBottomRef} />
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
