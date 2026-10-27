import { useState } from "react";

import { AddServerDialog } from "@/components/AddServerDialog";
import { ServerCard } from "@/components/ServerCard";
import { IconServer } from "@/components/icons";
import { Button } from "@/components/ui/Button";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { toast } from "@/components/ui/Toast";
import { useServers } from "@/lib/queries";

/** 总览：全部服务器卡片 + 在线状态 + 资源迷你条。 */
export function DashboardPage() {
  const { data, isLoading, isError, error, refetch, isFetching } = useServers();
  const [addOpen, setAddOpen] = useState(false);

  const servers = data ?? [];
  const online = servers.filter((s) => s.connection_status === "online").length;
  const offline = servers.filter((s) => s.connection_status === "offline").length;

  const onError = (msg: string) => toast(msg, "danger");

  return (
    <div className="space-y-5">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-h1 text-text">总览</h1>
          <p className="mt-1 text-body-sm text-text-muted">
            共 {servers.length} 台 · 在线 {online} · 离线 {offline}
            {isFetching ? " · 刷新中" : ""}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button variant="secondary" onClick={() => void refetch()} disabled={isFetching}>
            刷新
          </Button>
          <Button variant="primary" onClick={() => setAddOpen(true)}>
            添加服务器
          </Button>
        </div>
      </div>

      {isLoading ? (
        <div className="rounded-card border border-border bg-surface-1">
          <SkeletonRows rows={4} cols={5} />
        </div>
      ) : isError ? (
        <div className="rounded-card border border-border bg-surface-1">
          <ErrorState message={error instanceof Error ? error.message : "加载失败"} onRetry={() => void refetch()} />
        </div>
      ) : servers.length === 0 ? (
        <div className="rounded-card border border-border bg-surface-1">
          <EmptyState
            title="还没有纳管服务器"
            description="点「添加服务器」，填入 SSH 地址与凭据即可。凭据会加密存储在控制面本地，不会明文落库。"
            action={
              <Button variant="primary" onClick={() => setAddOpen(true)}>
                <IconServer />
                添加第一台服务器
              </Button>
            }
          />
        </div>
      ) : (
        <div className="grid grid-cols-1 gap-4 md:grid-cols-2 xl:grid-cols-3">
          {servers.map((s) => (
            <ServerCard key={s.id} server={s} onError={onError} />
          ))}
        </div>
      )}

      <AddServerDialog
        open={addOpen}
        onClose={() => setAddOpen(false)}
        onError={onError}
      />
    </div>
  );
}
