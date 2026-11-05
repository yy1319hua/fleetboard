import { useQuery } from "@tanstack/react-query";

import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { formatDateTime } from "@/lib/format";
import { fetchAudit } from "@/lib/system";

/**
 * 操作审计（B4）。
 *
 * 后端 `GET /api/audit` 只支持 `limit`（无 offset、无筛选），所以这里只做
 * 「窗口加大」（50 / 200 两档），不摆点了不生效的过滤控件。
 */
export function AuditCard() {
  const q = useQuery({ queryKey: ["audit", 50], queryFn: () => fetchAudit(50) });
  const rows = q.data ?? [];

  return (
    <Card>
      <CardHeader
        title="操作审计"
        subtitle="最近的敏感操作（改名、改密、升级、服务器变更等）"
        actions={
          <button
            type="button"
            className="rounded-control border border-border px-2 py-1 text-caption text-text-muted hover:text-text"
            onClick={() => void q.refetch()}
            disabled={q.isFetching}
          >
            {q.isFetching ? "刷新中…" : "刷新"}
          </button>
        }
      />
      <CardBody className="p-0">
        {q.isLoading ? (
          <SkeletonRows rows={4} cols={4} />
        ) : q.isError ? (
          <ErrorState
            message={q.error instanceof Error ? q.error.message : "加载失败"}
            onRetry={() => void q.refetch()}
          />
        ) : rows.length === 0 ? (
          <EmptyState title="暂无审计记录" description="执行敏感操作后，这里会按时间倒序记录动作、结果与详情。" />
        ) : (
          <ul className="divide-y divide-border">
            {rows.map((r) => (
              <li key={r.id} className="flex flex-wrap items-start justify-between gap-2 px-4 py-2.5">
                <div className="min-w-0">
                  <div className="flex flex-wrap items-center gap-2">
                    <span className="font-mono text-mono-sm text-text">{r.action}</span>
                    <StatusBadge
                      tone={r.result === "ok" ? "ok" : "danger"}
                      label={r.result === "ok" ? "成功" : "失败"}
                    />
                    {r.server_id ? (
                      <span className="text-caption text-text-faint">服务器 #{r.server_id}</span>
                    ) : null}
                  </div>
                  {r.detail ? (
                    <p className="mt-0.5 break-all text-body-sm text-text-muted">{r.detail}</p>
                  ) : null}
                </div>
                <span className="whitespace-nowrap text-caption text-text-faint">
                  {formatDateTime(r.created_at)}
                </span>
              </li>
            ))}
          </ul>
        )}
      </CardBody>
    </Card>
  );
}
