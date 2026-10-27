import { cn } from "@/lib/cn";

/**
 * 迷你占比条：CPU / 内存 / 磁盘。
 * 遵循 DESIGN.md：颜色只表达状态且必须配文字，数字用 tabular-nums 对齐。
 */
function toneOf(pct: number): { bar: string; text: string } {
  if (pct >= 85) return { bar: "bg-danger", text: "text-danger" };
  if (pct >= 70) return { bar: "bg-warn", text: "text-warn" };
  return { bar: "bg-ok", text: "text-text" };
}

export function MiniBar({
  label,
  value,
  className,
}: {
  label: string;
  /** 百分比 0–100；null 表示无数据 */
  value: number | null;
  className?: string;
}) {
  const pct = value === null ? null : Math.max(0, Math.min(100, value));
  const tone = pct === null ? null : toneOf(pct);

  return (
    <div className={cn("min-w-0", className)}>
      <div className="flex items-baseline justify-between gap-2">
        <span className="text-caption text-text-faint">{label}</span>
        <span className={cn("tabular text-caption", tone ? tone.text : "text-text-faint")}>
          {pct === null ? "—" : `${pct.toFixed(0)}%`}
        </span>
      </div>
      <div
        className="mt-1 h-1 w-full overflow-hidden rounded-pill bg-surface-3"
        role="img"
        aria-label={`${label} ${pct === null ? "无数据" : `${pct.toFixed(0)}%`}`}
      >
        {pct === null ? null : (
          <div className={cn("h-full rounded-pill transition-[width] duration-ui ease-ui", tone?.bar)} style={{ width: `${pct}%` }} />
        )}
      </div>
    </div>
  );
}
