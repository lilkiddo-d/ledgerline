const palette = ["#5b8cff", "#7ef0c4", "#f5b84b", "#c792ea", "#ff8f6b", "#4fd1e8", "#e5e07a", "#9aa5ff", "#ff7aa8", "#7bd88f"];

export function AssetIcon({ symbol }: { symbol: string }) {
  let h = 0;
  for (const c of symbol) h = (h * 31 + c.charCodeAt(0)) >>> 0;
  const color = palette[h % palette.length];
  return (
    <span className="asset-icon" style={{ color, borderColor: color }} aria-hidden>
      {symbol.slice(0, 2)}
    </span>
  );
}
