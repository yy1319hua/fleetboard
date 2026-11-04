import { useMemo, useState } from "react";
import { useOutletContext } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import {
  CartesianGrid,
  Legend,
  Line,
  LineChart,
  ReferenceLine,
  ResponsiveContainer,
  Tooltip,
  XAxis,
  YAxis,
} from "recharts";

import { Button } from "@/components/ui/Button";
import { EmptyState, ErrorState, Skeleton } from "@/components/ui/Feedback";
import { apiGet } from "@/lib/api";
import { formatDateTime, formatRelative } from "@/lib/format";
import { cn } from "@/lib/cn";
import type { Server, ServerMetric } from "@/lib/types";

interface Ctx {
  server: Server;
}

type Range = "24h" | "7d";

interface MetricsResponse {
  range: string;
  count: number;
  points: ServerMetric[];
}

/** 前端抽稀：把采样点按时间窗口聚合成最多 maxPoints 个点，避免 7d 数据把曲线画糊。 */
function downsample(points: ServerMetric[], maxPoints = 240): ServerMetric[] {
  if (points.length <= maxPoints) return points;
  const bucket = Math.ceil(points.length / maxPoints);
  const out: ServerMetric[] = [];
  for (let i = 0; i < points.length; i += bucket) {
    const slice = points.slice(i, i + bucket);
    const n = slice.length;
    const avg = (pick: (m: ServerMetric) => number) => slice.reduce((s, m) => s + pick(m), 0) / n;
    // 用桶内最后一条的时间戳，指标取均值（避免尖峰被误读为常态）
    const last = slice[n - 1];
    if (!last) continue;
    out.push({
      ...last,
      cpu_pct: avg((m) => m.cpu_pct),
      mem_pct: avg((m) => m.mem_pct),
      disk_pct: avg((m) => m.disk_pct),
      load1: avg((m) => m.load1),
    });
  }
  return out;
}

/** 依据时间跨度选择轴标签格式：24h 显示时分，7d 显示月-日。 */
function tickLabel(iso: string, range: Range): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n: number) => String(n).padStart(2, "0");
  if (range === "24h") return `${p(d.getHours())}:${p(d.getMinutes())}`;
  return `${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

const SERIES = [
  { key: "cpu_pct", label: "CPU %", color: "var(--chart-accent)" },
  { key: "mem_pct", label: "内存 %", color: "var(--chart-info)" },
  { key: "disk_pct", label: "磁盘 %", color: "var(--chart-ok)" },
] as const;

export function ServerMonitorTab() {
  const { server } = useOutletContext<Ctx>();
  const [range, setRange] = useState<Range>("24h");
  // 游标位置：鼠标/手指在图上移动时记录索引，顶部数值卡跟着变；
  // 离开图表后回到「最新采样」。null 表示没有游标。
  const [cursorIdx, setCursorIdx] = useState<number | null>(null);

  const { data, isLoading, isError, error, refetch, isFetching } = useQuery({
    queryKey: ["metrics", server.id, range],
    queryFn: () => apiGet<MetricsResponse>(`/api/servers/${server.id}/metrics?range=${range}`),
    refetchInterval: 60_000,
  });

  const points = useMemo(() => downsample(data?.points ?? []), [data]);
  const latest = points.length > 0 ? points[points.length - 1] : null;
  // 游标点有效时才接管顶部数值卡，否则回落最新点。
  const cursorPoint =
    cursorIdx !== null && cursorIdx >= 0 && cursorIdx < points.length ? points[cursorIdx] : null;
  const active = cursorPoint ?? latest;

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-1 rounded-control border border-border bg-surface-1 p-0.5">
          {(["24h", "7d"] as Range[]).map((r) => (
            <button
              key={r}
              type="button"
              onClick={() => setRange(r)}
              className={cn(
                "min-h-11 rounded-[5px] px-3 text-body-sm transition-colors duration-ui ease-ui sm:min-h-0 sm:h-8",
                range === r ? "bg-accent-soft text-text" : "text-text-muted hover:text-text",
              )}
            >
              {r === "24h" ? "最近 24 小时" : "最近 7 天"}
            </button>
          ))}
        </div>
        <div className="flex items-center gap-2 text-caption text-text-faint">
          <span className="tabular">
            {data ? `${data.count} 个采样点` : "—"}
            {points.length !== (data?.count ?? 0) ? `（绘图抽稀至 ${points.length}）` : ""}
          </span>
          <Button size="sm" variant="secondary" onClick={() => void refetch()} disabled={isFetching}>
            刷新
          </Button>
        </div>
      </div>

      {active ? (
        <div className="rounded-card border border-border bg-surface-1">
          <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-2">
            <span className="text-caption text-text-faint">
              {cursorPoint ? "游标位置" : "最新采样"}
            </span>
            <span className="tabular text-caption text-text-muted">{formatDateTime(active.ts)}</span>
          </div>
          <div className="grid grid-cols-2 gap-4 px-4 py-3 sm:grid-cols-4">
            <div>
              <div className="eyebrow">CPU</div>
              <div className="tabular mt-0.5 text-h1 text-text">{active.cpu_pct.toFixed(1)}%</div>
            </div>
            <div>
              <div className="eyebrow">内存</div>
              <div className="tabular mt-0.5 text-h1 text-text">{active.mem_pct.toFixed(1)}%</div>
            </div>
            <div>
              <div className="eyebrow">磁盘</div>
              <div className="tabular mt-0.5 text-h1 text-text">{active.disk_pct.toFixed(1)}%</div>
            </div>
            <div>
              <div className="eyebrow">负载 1m</div>
              <div className="tabular mt-0.5 text-h1 text-text">{active.load1.toFixed(2)}</div>
            </div>
          </div>
        </div>
      ) : null}

      <div className="rounded-card border border-border bg-surface-1">
        <div className="flex items-center justify-between border-b border-border px-4 py-3">
          <h2 className="text-h3 text-text">资源趋势</h2>
          {latest ? <span className="text-caption text-text-faint">最新采样 {formatRelative(latest.ts)}</span> : null}
        </div>

        <div className="px-2 py-4 sm:px-4">
          {isLoading ? (
            <div className="space-y-2 px-2">
              <Skeleton className="h-64 w-full" />
            </div>
          ) : isError ? (
            <ErrorState
              message={error instanceof Error ? error.message : "加载监控数据失败"}
              onRetry={() => void refetch()}
            />
          ) : points.length === 0 ? (
            <EmptyState
              title="暂无历史采样"
              description="采集任务默认每 30 秒运行一次；纳管后需等待一段时间才有曲线。若服务器离线，采集不会产生数据。"
            />
          ) : (
            <div className="h-[320px] w-full">
              <ResponsiveContainer width="100%" height="100%">
                <LineChart
                  data={points}
                  margin={{ top: 8, right: 12, bottom: 4, left: 0 }}
                  // 鼠标/手指横向移动 → 记录游标索引，顶部数值卡与竖线一起跟随。
                  // recharts 的 activeTooltipIndex 在触摸拖动时同样会更新，移动端可用。
                  onMouseMove={(state) => {
                    const i = (state as { activeTooltipIndex?: number } | null)?.activeTooltipIndex;
                    if (typeof i === "number" && i >= 0) setCursorIdx(i);
                  }}
                  onMouseLeave={() => setCursorIdx(null)}
                >
                  <CartesianGrid stroke="var(--chart-grid)" strokeDasharray="2 4" vertical={false} />
                  <XAxis
                    dataKey="ts"
                    tickFormatter={(v: string) => tickLabel(v, range)}
                    stroke="var(--chart-axis)"
                    tick={{ fontSize: 11, fill: "var(--chart-tick)" }}
                    minTickGap={40}
                  />
                  <YAxis
                    domain={[0, 100]}
                    stroke="var(--chart-axis)"
                    tick={{ fontSize: 11, fill: "var(--chart-tick)" }}
                    width={48}
                    tickFormatter={(v: number) => `${v}%`}
                  />
                  <Tooltip
                    contentStyle={{
                      background: "var(--chart-tooltip-bg)",
                      border: "1px solid var(--chart-tooltip-border)",
                      borderRadius: 6,
                      fontSize: 12,
                    }}
                    labelStyle={{ color: "var(--chart-tick)" }}
                    labelFormatter={(v: string) => new Date(v).toLocaleString("zh-CN")}
                    formatter={(value: number, name: string) => [`${value.toFixed(1)}%`, name]}
                  />
                  <Legend
                    verticalAlign="top"
                    height={28}
                    formatter={(v: string) => <span style={{ color: "var(--chart-tick)", fontSize: 12 }}>{v}</span>}
                  />
                  {cursorPoint ? (
                    <ReferenceLine x={cursorPoint.ts} stroke="var(--chart-tick)" strokeDasharray="3 3" />
                  ) : null}
                  {SERIES.map((s) => (
                    <Line
                      key={s.key}
                      type="monotone"
                      dataKey={s.key}
                      name={s.label}
                      stroke={s.color}
                      strokeWidth={1.6}
                      dot={false}
                      isAnimationActive={false}
                    />
                  ))}
                </LineChart>
              </ResponsiveContainer>
            </div>
          )}
        </div>
      </div>

      <p className="text-caption text-text-faint">
        在曲线上左右移动鼠标（手机上是手指拖动），可查看该时刻的具体数值。采样间隔与保留天数可在控制面配置（默认 30 秒 /
        30 天）。曲线为前端抽稀后的均值，尖峰可能被平滑。
      </p>
    </div>
  );
}
