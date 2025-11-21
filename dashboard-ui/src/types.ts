export interface Agent {
    id: string;
    port: number;
    pid: number;
    status: 'ready' | 'busy' | 'error' | 'stopped';
    last_event?: string;
}

export type EventType =
    | 'AGENT_START'
    | 'AGENT_STOP'
    | 'TOOL_CALL'
    | 'CODE_EXECUTION'
    | 'OUTPUT'
    | 'ERROR'
    | 'HEARTBEAT';

export interface AgentEvent {
    id: string;
    type: EventType;
    timestamp: string;
    data: Record<string, any>;
    duration_ms?: number | null;
}

export interface DashboardData {
    agents: Record<string, Agent>;
    events: AgentEvent[];
}
