import { hfColor } from "@/lib/risk";

/** Semicircular health-factor gauge: 1.0 (liquidation) on the left, 3.0+ on the right. */
export function HealthGauge({ hf, size = 200 }: { hf: number; size?: number }) {
  const min = 1;
  const max = 3;
  const clamped = Number.isFinite(hf) ? Math.min(Math.max(hf, 0), max) : max;
  const t = Math.max(0, (clamped - min) / (max - min));
  const r = size / 2 - 14;
  const cx = size / 2;
  const cy = size / 2;
  const angle = Math.PI * (1 - t);
  const nx = cx + r * Math.cos(angle);
  const ny = cy - r * Math.sin(angle);
  const color = hfColor(hf);
  const label = !Number.isFinite(hf) ? "∞" : hf > 100 ? ">100" : hf.toFixed(2);
  const arc = (from: number, to: number) => {
    const a0 = Math.PI * (1 - from);
    const a1 = Math.PI * (1 - to);
    const x0 = cx + r * Math.cos(a0), y0 = cy - r * Math.sin(a0);
    const x1 = cx + r * Math.cos(a1), y1 = cy - r * Math.sin(a1);
    return `M ${x0} ${y0} A ${r} ${r} 0 0 1 ${x1} ${y1}`;
  };
  return (
    <svg width={size} height={size / 2 + 34} viewBox={`0 0 ${size} ${size / 2 + 34}`} role="img" aria-label={`Health factor ${label}`}>
      <path d={arc(0, 0.1)} stroke="var(--bad)" strokeWidth="10" fill="none" strokeLinecap="round" />
      <path d={arc(0.1, 0.5)} stroke="var(--warn)" strokeWidth="10" fill="none" />
      <path d={arc(0.5, 1)} stroke="var(--good)" strokeWidth="10" fill="none" strokeLinecap="round" />
      <line x1={cx} y1={cy} x2={nx} y2={ny} stroke={color} strokeWidth="3" strokeLinecap="round" />
      <circle cx={cx} cy={cy} r="5" fill={color} />
      <text x={cx} y={cy + 28} textAnchor="middle" fill="var(--text)" fontSize="22" fontWeight="700">
        {label}
      </text>
    </svg>
  );
}
