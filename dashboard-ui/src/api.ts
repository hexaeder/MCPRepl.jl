import { Session, SessionEvent } from './types';

const API_BASE = '/dashboard/api';

export async function fetchSessions(): Promise<Record<string, Session>> {
    const response = await fetch(`${API_BASE}/sessions`);
    if (!response.ok) throw new Error('Failed to fetch sessions');
    return response.json();
}

export async function fetchEvents(sessionId?: string, limit: number = 100): Promise<SessionEvent[]> {
    const params = new URLSearchParams();
    if (sessionId) params.set('id', sessionId);
    params.set('limit', limit.toString());

    const response = await fetch(`${API_BASE}/events?${params}`);
    if (!response.ok) throw new Error('Failed to fetch events');
    return response.json();
}

export function subscribeToEvents(
    onEvent: (event: SessionEvent) => void,
    sessionId?: string
): () => void {
    const params = new URLSearchParams();
    if (sessionId) params.set('id', sessionId);

    const eventSource = new EventSource(`${API_BASE}/events/stream?${params}`);

    eventSource.addEventListener('update', (e) => {
        try {
            const event = JSON.parse(e.data) as SessionEvent;
            onEvent(event);
        } catch (error) {
            console.error('Failed to parse event:', error);
        }
    });

    eventSource.onerror = (error) => {
        console.error('SSE error:', error);
    };

    // Return cleanup function
    return () => {
        eventSource.close();
    };
}

export interface ToolSchema {
    name: string;
    description: string;
    inputSchema: {
        type: string;
        properties?: Record<string, any>;
        required?: string[];
    };
}

export interface ToolsResponse {
    proxy_tools: ToolSchema[];
    session_tools: Record<string, ToolSchema[]>;
}

export async function fetchTools(sessionId?: string): Promise<ToolsResponse> {
    const headers: Record<string, string> = {};
    if (sessionId) {
        headers['X-Agent-Id'] = sessionId;
    }

    const response = await fetch(`${API_BASE}/tools`, { headers });
    if (!response.ok) throw new Error('Failed to fetch tools');
    return response.json();
}

export interface ToolCallRequest {
    tool: string;
    arguments: Record<string, any>;
    sessionId?: string;
}

export interface ToolCallResponse {
    result?: any;
    error?: any;
}

export async function callTool(request: ToolCallRequest): Promise<ToolCallResponse> {
    const mcpRequest = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
            name: request.tool,
            arguments: request.arguments
        }
    };

    const headers: Record<string, string> = {
        'Content-Type': 'application/json'
    };

    if (request.sessionId) {
        headers['X-Agent-Id'] = request.sessionId;
    }

    const response = await fetch('/', {
        method: 'POST',
        headers,
        body: JSON.stringify(mcpRequest)
    });

    if (!response.ok) throw new Error('Failed to call tool');

    const data = await response.json();
    return {
        result: data.result,
        error: data.error
    };
}

export interface LogFile {
    name: string;
    size: number;
    modified: string;
}

export interface LogsResponse {
    content?: string;
    file?: string;
    total_lines?: number;
    files?: LogFile[];
    error?: string;
}

export async function fetchLogs(sessionId?: string, lines: number = 500): Promise<LogsResponse> {
    const params = new URLSearchParams();
    if (sessionId) params.set('session_id', sessionId);
    params.set('lines', lines.toString());

    const response = await fetch(`${API_BASE}/logs?${params}`);
    if (!response.ok) throw new Error('Failed to fetch logs');
    return response.json();
}

export interface DirectoriesResponse {
    directories: string[];
    is_julia_project?: boolean;
    error?: string;
}

export async function fetchDirectories(path: string): Promise<DirectoriesResponse> {
    const params = new URLSearchParams();
    params.set('path', path);

    const response = await fetch(`${API_BASE}/directories?${params}`);
    if (!response.ok) throw new Error('Failed to fetch directories');
    return response.json();
}

export interface ShutdownSessionResponse {
    success: boolean;
    session_id: string;
}

export async function shutdownSession(sessionId: string): Promise<ShutdownSessionResponse> {
    const response = await fetch(`${API_BASE}/session/${sessionId}/shutdown`, {
        method: 'POST'
    });
    if (!response.ok) throw new Error('Failed to shutdown session');
    return response.json();
}

export async function restartSession(sessionId: string): Promise<ShutdownSessionResponse> {
    const response = await fetch(`${API_BASE}/session/${sessionId}/restart`, {
        method: 'POST'
    });
    if (!response.ok) {
        const text = await response.text();
        throw new Error(`Failed to restart session: ${response.status} ${text}`);
    }
    return response.json();
}

export interface StaleSession {
    pid: number;
    session_name: string;
    is_stale: boolean;
}

export interface StaleSessionsResponse {
    sessions: StaleSession[];
    count: number;
}

export async function listStaleSessions(): Promise<StaleSessionsResponse> {
    const mcpRequest = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
            name: "kill_stale_sessions",
            arguments: { dry_run: true }
        }
    };

    const response = await fetch(API_BASE, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(mcpRequest)
    });

    if (!response.ok) throw new Error('Failed to list stale sessions');
    const data = await response.json();

    // Parse the text response
    const text = data.result?.content?.[0]?.text || '';
    const sessions: StaleSession[] = [];

    const lines = text.split('\n');
    for (const line of lines) {
        const match = line.match(/PID (\d+): ([^\s]+) - (.*?)$/);
        if (match) {
            sessions.push({
                pid: parseInt(match[1]),
                session_name: match[2],
                is_stale: match[3].includes('STALE')
            });
        }
    }

    return { sessions, count: sessions.length };
}

export async function killStaleSessions(force: boolean = false): Promise<string> {
    const mcpRequest = {
        jsonrpc: "2.0",
        id: 1,
        method: "tools/call",
        params: {
            name: "kill_stale_sessions",
            arguments: { dry_run: false, force }
        }
    };

    const response = await fetch(API_BASE, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(mcpRequest)
    });

    if (!response.ok) throw new Error('Failed to kill stale sessions');
    const data = await response.json();
    return data.result?.content?.[0]?.text || 'Unknown result';
}

// Quick start now uses callTool() directly
