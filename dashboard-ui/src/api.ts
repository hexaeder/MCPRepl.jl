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
