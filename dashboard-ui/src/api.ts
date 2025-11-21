import { Session, SessionEvent } from './types';

const API_BASE = '/dashboard/api';

export async function fetchSessions(): Promise<Record<string, Session>> {
    const response = await fetch(`${API_BASE}/agents`);
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
