import React, { useEffect, useRef, useState } from 'react';
import { Line } from 'recharts';
import { LineChart, ResponsiveContainer, XAxis, YAxis } from 'recharts';

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

  useEffect(() => {
    // Initialize with baseline
    const initialData: DataPoint[] = [];
    for (let i = 0; i < 100; i++) {
      initialData.push({
        time: i,
        value: 0.5 + (Math.random() - 0.5) * 0.1
      });
    }
    dataRef.current = initialData;
    setData(initialData);

    // Animate
    let animationId: number;
    const animate = () => {
      const now = Date.now();
      const newData = [...dataRef.current];
      
      // Shift data left
      newData.shift();
      
      // Check if heartbeat should trigger (every ~1 second)
      const timeSinceLastBeat = now - lastBeatRef.current;
      let newValue: number;
      
      if (timeSinceLastBeat > 1000) {
        lastBeatRef.current = now;
        // Start of heartbeat spike
        newValue = 0.5 + Math.sin(0) * 0.4;
      } else if (timeSinceLastBeat < 100) {
        // During heartbeat (100ms duration)
        const progress = timeSinceLastBeat / 100;
        newValue = 0.5 + Math.sin(progress * Math.PI * 4) * 0.4;
      } else {
        // Normal baseline with noise
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
          stroke="#00d9ff"
          strokeWidth={2}
          dot={false}
          isAnimationActive={false}
        />
      </LineChart>
    </ResponsiveContainer>
  );
};
