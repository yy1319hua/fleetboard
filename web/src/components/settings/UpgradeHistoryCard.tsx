import { useQuery } from "@tanstack/react-query";

import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { StatusBadge, type Tone } from "@/components/ui/StatusBadge";
import { formatDateTime } from "@/lib/format";
import { fetchUpgradeHistory } from "@/lib/system";

const STATUS_LABEL: Record<string, string> = {
  done: "成功",
  success: "成功",
  failed: "失败",
  running: "进行中",
};

function tone(s: string): Tone {
  if (s === "done" || s === "success") return "ok";
  if (s === "failed") return "danger";
  return "info";
}

function duration(ms: number): string {
  if (!ms) return "—";
  if (ms < 1000) return `${ms} ms`;
  const s = Math.round(ms / 1000);
  return s < 60 ? `${s} s` : `${Math.floor(s / 60)} 分 ${s % 60} 秒`;
}

/** 升级历史（B3）：只读列表，后端无分页参数，按最近 N 条呈现。 */
export function UpgradeHistoryCard() {
  const q = useQuery({ queryKey: ["upgrade-history"], queryFn: fetchUpgradeHistory });

  return (
    <Card>
      <CardHeader title="升级历史" subtitle="最近的面板升级记录（只读）" />
      <CardBody className="p-0">
        {q.isLoading ? (
          <SkeletonRows rows={3} cols={4} />
        ) : q.isError ? (
          <ErrorState
            message={q.error instanceof Error ? q.error.message : "加载失败"}
            onRetry={() => void q.refetch()}
          />
        ) : (q.data ?? []).length === 0 ? (
          <EmptyState title="还没有升级记录" description="在「面板更新」里手动升级后，这里会留下版本、状态与耗时。" />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[520px] border-collapse">
              <thead className="bg-surface-2">
                <tr className="border-b border-border">
                  <th className="px-4 py-2 text-left"><span className="eyebrow">时间</span></th>
                  <th className="px-3 py-2 text-left"><span className="eyebrow">版本</span></th>
                  <th className="px-3 py-2 text-left"><span className="eyebrow">状态</span></th>
                  <th className="px-3 py-2 text-right"><span className="eyebrow">耗时</span></th>
                </tr>
              </thead>
              <tbody>
                {(q.data ?? []).map((r) => (
                  <tr key={r.id} className="h-10 border-b border-border last:border-0 hover:bg-surface-3">
                    <td className="whitespace-nowrap px-4 text-body-sm text-text-muted">
                      {formatDateTime(r.started_at)}
                    </td>
                    <td className="whitespace-nowrap px-3 font-mono text-mono-sm text-text">
                      {r.from_version} → {r.to_version}
                    </td>
                    <td className="px-3">
                      <StatusBadge tone={tone(r.status)} label={STATUS_LABEL[r.status] ?? r.status} />
                    </td>
                    <td className="tabular whitespace-nowrap px-3 text-right font-mono text-mono-sm text-text-muted">
                      {duration(r.duration_ms)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </CardBody>
    </Card>
  );
}
