import { Link, useOutletContext } from "react-router-dom";

import { MiniBar } from "@/components/MiniBar";
import { EmptyState, Skeleton } from "@/components/ui/Feedback";
import { StatusBadge, serverTone } from "@/components/ui/StatusBadge";
import { formatDateTime, formatKB, formatPct, formatRelative, formatUptime } from "@/lib/format";
import { useLatestMetric, useServerFacts } from "@/lib/queries";
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
  const { data: facts, isLoading: factsLoading } = useServerFacts(server.id);
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

      <section className="rounded-card border border-border bg-surface-1 lg:col-span-2">
        <div className="flex flex-wrap items-center justify-between gap-2 border-b border-border px-4 py-3">
          <h2 className="text-h3 text-text">系统配置</h2>
          {facts ? (
            <span className="text-caption text-text-faint">采集于 {formatRelative(facts.collected_at)}</span>
          ) : null}
        </div>

        {factsLoading ? (
          <div className="space-y-3 px-4 py-4">
            <Skeleton className="h-5 w-2/3" />
            <Skeleton className="h-5 w-1/2" />
          </div>
        ) : !facts ? (
          <EmptyState
            title="尚未采集到配置"
            description="后台每小时采集一次；服务器离线或刚纳管时暂无数据，恢复在线后会自动补齐。"
          />
        ) : (
          <>
            <div className="grid gap-x-8 px-4 py-1 sm:grid-cols-2">
              <Row label="CPU">
                {facts.cpu_model || "—"}
                {facts.cpu_cores > 0 ? (
                  <span className="ml-1 text-text-faint">· {facts.cpu_cores} 线程</span>
                ) : null}
              </Row>
              <Row label="内存">
                {formatKB(facts.mem_total_kb)}
                {facts.swap_total_kb > 0 ? (
                  <span className="ml-1 text-text-faint">（Swap {formatKB(facts.swap_total_kb)}）</span>
                ) : null}
              </Row>
              <Row label="系统">{facts.os_name || "—"}</Row>
              <Row label="内核">
                <span className="font-mono text-mono-sm">{facts.kernel || "—"}</span>
              </Row>
              <Row label="架构">{facts.arch || "—"}</Row>
              <Row label="虚拟化">{virtLabel(facts.virt)}</Row>
              <Row label="主机名">
                <span className="font-mono text-mono-sm">{facts.hostname || "—"}</span>
              </Row>
              <Row label="运行时长">{formatUptime(facts.uptime_sec)}</Row>
            </div>

            <div className="border-t border-border px-4 py-3">
              <div className="eyebrow mb-2">磁盘挂载点</div>
              {facts.disks.length === 0 ? (
                <p className="text-caption text-text-faint">
                  未读取到挂载点（可能只有 tmpfs 等虚拟文件系统）
                </p>
              ) : (
                <ul className="space-y-3">
                  {facts.disks.map((d) => (
                    <li key={`${d.device}-${d.mount}`}>
                      <div className="flex items-baseline justify-between gap-3">
                        <span className="min-w-0 truncate font-mono text-mono-sm text-text">{d.mount}</span>
                        <span className="tabular shrink-0 text-caption text-text-muted">
                          {formatKB(d.used_kb)} / {formatKB(d.total_kb)}
                        </span>
                      </div>
                      <MiniBar label={d.device || "—"} value={d.used_pct} className="mt-1" />
                    </li>
                  ))}
                </ul>
              )}
            </div>
          </>
        )}
      </section>
    </div>
  );
}

/** systemd-detect-virt 的返回值 → 中文标签；未知值原样显示，便于发现新类型。 */
function virtLabel(v: string): string {
  switch (v) {
    case "none":
      return "物理机";
    case "kvm":
      return "KVM 虚拟机";
    case "vmware":
      return "VMware 虚拟机";
    case "docker":
    case "podman":
      return "容器";
    case "lxc":
      return "LXC 容器";
    case "":
    case "unknown":
      return "—";
    default:
      return v;
  }
}
