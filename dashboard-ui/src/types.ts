export interface Session {
    id: string;
    port: number;
    pid: number;
    status: 'ready' | 'busy' | 'error' | 'stopped';
    last_event?: string;
}

export type EventType =
    | 'SESSION_START'
    | 'SESSION_STOP'
    | 'TOOL_CALL'
    | 'CODE_EXECUTION'
    | 'OUTPUT'
    | 'ERROR'
    | 'HEARTBEAT';

export interface SessionEvent {
    id: string;
    type: EventType;
    timestamp: string;
    data: Record<string, any>;
    duration_ms?: number | null;
}

export interface DashboardData {
    sessions: Record<string, Session>;
    events: SessionEvent[];
}
