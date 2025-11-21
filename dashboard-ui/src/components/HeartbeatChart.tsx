import React, { useEffect, useRef, useState } from 'react';
import { Line } from 'recharts';
import { LineChart, ResponsiveContainer, XAxis, YAxis } from 'recharts';
import { subscribeToEvents } from '../api';
import { AgentEvent } from '../types';

interface HeartbeatChartProps {
    agentId: string;
}

interface DataPoint {
    time: number;
    value: number;
}

export const HeartbeatChart: React.FC<HeartbeatChartProps> = ({ agentId }) => {
    const [data, setData] = useState<DataPoint[]>([]);
    const dataRef = useRef<DataPoint[]>([]);
    const lastBeatRef = useRef<number>(0);
    const spikeStateRef = useRef<{ active: boolean; startTime: number; amplitude: number; duration: number }>({
        active: false,
        startTime: 0,
        amplitude: 0.35,
        duration: 100
    });

    useEffect(() => {
        // Initialize with baseline (double the points for slower scrolling)
        const initialData: DataPoint[] = [];
        for (let i = 0; i < 200; i++) {
            initialData.push({
                time: i,
                value: 0.5 + (Math.random() - 0.5) * 0.1
            });
        }
        dataRef.current = initialData;
        setData(initialData);

        let frameCount = 0;

        // Subscribe to real-time heartbeat events via SSE
        const unsubscribe = subscribeToEvents((event: AgentEvent) => {
            if (event.type === 'HEARTBEAT' && event.id === agentId) {
                const eventTime = new Date(event.timestamp).getTime();
                const now = Date.now();
                
                // Avoid duplicate spikes
                if (eventTime > lastBeatRef.current) {
                    lastBeatRef.current = eventTime;
                    // Trigger spike with randomized characteristics
                    spikeStateRef.current = {
                        active: true,
                        startTime: now,
                        amplitude: 0.35 + Math.random() * 0.08,
                        duration: 90 + Math.random() * 20
                    };
                }
            }
        }, agentId);

        // Animate
        let animationId: number;
        const animate = () => {
            frameCount++;
            // Only update every other frame to slow down horizontal movement
            if (frameCount % 2 !== 0) {
                animationId = requestAnimationFrame(animate);
                return;
            }

            const now = Date.now();
            const newData = [...dataRef.current];

            // Shift data left
            newData.shift();

            let newValue: number;
            const spike = spikeStateRef.current;
            const timeSinceSpike = now - spike.startTime;

            if (spike.active && timeSinceSpike < spike.duration) {
                // During heartbeat spike
                const progress = timeSinceSpike / spike.duration;
                const waveVariation = 3.8 + Math.random() * 0.4;
                newValue = 0.5 + Math.sin(progress * Math.PI * waveVariation) * spike.amplitude;
            } else {
                // Normal baseline with noise
                spike.active = false;
                newValue = 0.5 + (Math.random() - 0.5) * 0.1;
            }

            newData.push({
                time: newData[newData.length - 1].time + 1,
                value: newValue
            });

            dataRef.current = newData;
            setData(newData);

            animationId = requestAnimationFrame(animate);
        };

        animationId = requestAnimationFrame(animate);

        return () => {
            cancelAnimationFrame(animationId);
            unsubscribe();
        };
    }, [agentId]);

    return (
        <ResponsiveContainer width="100%" height="100%">
            <LineChart data={data} margin={{ top: 5, right: 5, bottom: 5, left: 5 }}>
                <XAxis dataKey="time" hide />
                <YAxis domain={[0, 1]} hide />
                <Line
                    type="monotone"
                    dataKey="value"
                    stroke="#7dd3fc"
                    strokeWidth={1.5}
                    strokeOpacity={0.7}
                    dot={false}
                    isAnimationActive={false}
                />
            </LineChart>
        </ResponsiveContainer>
    );
};
