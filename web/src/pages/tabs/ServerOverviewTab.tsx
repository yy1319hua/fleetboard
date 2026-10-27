import { Link, useOutletContext } from "react-router-dom";

import { MiniBar } from "@/components/MiniBar";
import { EmptyState, Skeleton } from "@/components/ui/Feedback";
import { StatusBadge, serverTone } from "@/components/ui/StatusBadge";
import { formatDateTime, formatPct, formatRelative } from "@/lib/format";
import { useLatestMetric } from "@/lib/queries";
import type { Server } from "@/lib/types";

interface Ctx {
  server: Server;
}

function Row({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-start justify-between gap-4 py-2">
      <span className="shrink-0 text-body-sm text-text-faint">{label}</span>
      <span className="min-w-0 break-all text-right text-body-sm text-text">{children}</span>
    </div>
  );
}

/** 概览标签页：基础信息 + 当前资源 + 快捷入口。 */
export function ServerOverviewTab() {
  const { server } = useOutletContext<Ctx>();
  const { data: metric, isLoading } = useLatestMetric(server.id);
  const status = serverTone(server.connection_status);

  return (
    <div className="grid grid-cols-1 gap-4 lg:grid-cols-2">
      <section className="rounded-card border border-border bg-surface-1">
        <div className="border-b border-border px-4 py-3">
          <h2 className="text-h3 text-text">基础信息</h2>
        </div>
        <div className="divide-y divide-border px-4 py-1">
          <Row label="状态">
            <StatusBadge tone={status.tone} label={status.label} />
          </Row>
          <Row label="地址">
            <span className="font-mono text-mono-sm">
              {server.host}:{server.port}
            </span>
          </Row>
          <Row label="SSH 用户">
            <span className="font-mono text-mono-sm">{server.ssh_user}</span>
          </Row>
          <Row label="认证方式">{server.auth_method === "key" ? "SSH 私钥" : "密码"}</Row>
          <Row label="最后心跳">{formatRelative(server.last_heartbeat)}</Row>
          <Row label="纳管时间">{formatDateTime(server.created_at)}</Row>
        </div>
      </section>

      <section className="rounded-card border border-border bg-surface-1">
        <div className="border-b border-border px-4 py-3">
          <h2 className="text-h3 text-text">当前资源</h2>
        </div>

        {isLoading ? (
          <div className="space-y-3 px-4 py-4">
            <Skeleton className="h-6 w-2/3" />
            <Skeleton className="h-6 w-1/2" />
          </div>
        ) : !metric ? (
          <EmptyState
            title="暂无采样数据"
            description="采集任务默认每 30 秒运行一次；若刚纳管，请稍候刷新。"
          />
        ) : (
          <div className="space-y-3 px-4 py-4">
            <div className="grid grid-cols-2 gap-4">
              <div>
                <div className="eyebrow">CPU</div>
                <div className="tabular mt-1 text-display text-text">{formatPct(metric.cpu_pct)}</div>
              </div>
              <div>
                <div className="eyebrow">内存</div>
                <div className="tabular mt-1 text-display text-text">{formatPct(metric.mem_pct)}</div>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4 border-t border-border pt-3">
              <MiniBar label="磁盘" value={metric.disk_pct} />
              <div>
                <div className="flex items-baseline justify-between">
                  <span className="text-caption text-text-faint">负载（1m）</span>
                  <span className="tabular text-caption text-text">{metric.load1.toFixed(2)}</span>
                </div>
              </div>
            </div>

            <p className="border-t border-border pt-2 text-caption text-text-faint">
              采样时间 {formatRelative(metric.ts)}
            </p>
          </div>
        )}

        <div className="flex flex-wrap gap-2 border-t border-border px-4 py-3">
          <Link className="text-body-sm text-accent hover:underline hover:underline-offset-2" to={`/servers/${server.id}/docker`}>
            容器 →
          </Link>
          <Link className="text-body-sm text-accent hover:underline hover:underline-offset-2" to={`/servers/${server.id}/files`}>
            文件 →
          </Link>
          <Link className="text-body-sm text-accent hover:underline hover:underline-offset-2" to={`/servers/${server.id}/monitor`}>
            监控曲线 →
          </Link>
        </div>
      </section>
    </div>
  );
}
