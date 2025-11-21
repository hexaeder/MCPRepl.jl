import { Agent, AgentEvent } from './types';

const API_BASE = '/dashboard/api';

export async function fetchAgents(): Promise<Record<string, Agent>> {
    const response = await fetch(`${API_BASE}/agents`);
    if (!response.ok) throw new Error('Failed to fetch agents');
    return response.json();
}

export async function fetchEvents(agentId?: string, limit: number = 100): Promise<AgentEvent[]> {
    const params = new URLSearchParams();
    if (agentId) params.set('id', agentId);
    params.set('limit', limit.toString());

    const response = await fetch(`${API_BASE}/events?${params}`);
    if (!response.ok) throw new Error('Failed to fetch events');
    return response.json();
}

export function subscribeToEvents(
    onEvent: (event: AgentEvent) => void,
    agentId?: string
): () => void {
    const params = new URLSearchParams();
    if (agentId) params.set('id', agentId);
    
    const eventSource = new EventSource(`${API_BASE}/events/stream?${params}`);
    
    eventSource.addEventListener('update', (e) => {
        try {
            const event = JSON.parse(e.data) as AgentEvent;
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
