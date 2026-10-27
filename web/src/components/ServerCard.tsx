import { Link } from "react-router-dom";

import { MiniBar } from "@/components/MiniBar";
import { IconServer } from "@/components/icons";
import { Button } from "@/components/ui/Button";
import { StatusBadge, Pill, serverTone } from "@/components/ui/StatusBadge";
import { formatRelative } from "@/lib/format";
import { useDeleteServer, useLatestMetric, useTestServer } from "@/lib/queries";
import type { Server } from "@/lib/types";

/**
 * 服务器卡片：状态 + 资源迷你条 + 快捷操作。
 * 卡片内部只用分隔线与区块，不再嵌套第二层卡（DESIGN.md 反模式）。
 */
export function ServerCard({ server, onError }: { server: Server; onError: (msg: string) => void }) {
  const status = serverTone(server.connection_status);
  const metric = useLatestMetric(server.id);
  const test = useTestServer();
  const del = useDeleteServer();

  const m = metric.data ?? null;

  const handleTest = () => {
    test.mutate(server.id, {
      onError: (err) => onError(err instanceof Error ? err.message : "连接测试失败"),
    });
  };

  const handleDelete = () => {
    const ok = window.confirm(
      `删除服务器「${server.name}」？\n\n仅从控制台移除记录，不会影响该服务器本身。`,
    );
    if (!ok) return;
    del.mutate(server.id, {
      onError: (err) => onError(err instanceof Error ? err.message : "删除失败"),
    });
  };

  return (
    <div className="flex flex-col rounded-card border border-border bg-surface-1">
      <div className="flex items-start justify-between gap-3 px-4 pt-3.5">
        <div className="min-w-0">
          <div className="flex items-center gap-2">
            <IconServer className="text-text-faint" />
            <Link
              to={`/servers/${server.id}`}
              className="truncate text-h3 text-text hover:text-accent hover:underline hover:underline-offset-2"
            >
              {server.name}
            </Link>
          </div>
          <div className="mt-1 truncate font-mono text-mono-sm text-text-muted">
            {server.ssh_user}@{server.host}:{server.port}
          </div>
        </div>
        <StatusBadge tone={status.tone} label={status.label} />
      </div>

      <div className="mt-3 grid grid-cols-3 gap-3 border-t border-border px-4 py-3">
        <MiniBar label="CPU" value={m ? m.cpu_pct : null} />
        <MiniBar label="内存" value={m ? m.mem_pct : null} />
        <MiniBar label="磁盘" value={m ? m.disk_pct : null} />
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2 border-t border-border px-4 py-2.5">
        <span className="text-caption text-text-faint">
          心跳 {formatRelative(server.last_heartbeat)}
        </span>

        <div className="flex items-center gap-1.5">
          {server.tags ? <Pill>{server.tags}</Pill> : null}
          <Button size="sm" variant="ghost" onClick={handleTest} loading={test.isPending}>
            测试
          </Button>
          <Button size="sm" variant="ghost" className="text-danger hover:text-danger" onClick={handleDelete} loading={del.isPending}>
            删除
          </Button>
          <Link
            to={`/servers/${server.id}`}
            className="inline-flex min-h-11 items-center rounded-control px-2.5 text-body-sm text-text-muted transition-colors duration-ui ease-ui hover:bg-surface-2 hover:text-text sm:min-h-0 sm:h-8"
          >
            管理 →
          </Link>
        </div>
      </div>
    </div>
  );
}
