import { NavLink, Outlet, useParams, useNavigate } from "react-router-dom";

import { Button } from "@/components/ui/Button";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { StatusBadge, serverTone } from "@/components/ui/StatusBadge";
import { toast } from "@/components/ui/Toast";
import { formatRelative } from "@/lib/format";
import { useDeleteServer, useServer, useTestServer } from "@/lib/queries";
import { cn } from "@/lib/cn";

const TABS = [
  { to: "", label: "概览", end: true },
  { to: "monitor", label: "监控", end: false },
  { to: "docker", label: "容器", end: false },
  { to: "files", label: "文件", end: false },
  { to: "compose", label: "Compose", end: false },
  { to: "packages", label: "软件包", end: false },
];

/** 服务器详情外壳：头部信息 + 标签页导航，子页面由嵌套路由渲染。 */
export function ServerDetailPage() {
  const { id } = useParams<{ id: string }>();
  const serverID = Number(id);
  const navigate = useNavigate();

  const { data: server, isLoading, isError, error, refetch } = useServer(serverID);
  const test = useTestServer();
  const del = useDeleteServer();

  if (!Number.isInteger(serverID) || serverID <= 0) {
    return <ErrorState message="服务器 ID 非法" />;
  }

  if (isLoading) {
    return (
      <div className="rounded-card border border-border bg-surface-1">
        <SkeletonRows rows={4} cols={4} />
      </div>
    );
  }

  if (isError || !server) {
    const status = (error as { status?: number } | null)?.status;
    return (
      <div className="rounded-card border border-border bg-surface-1">
        <ErrorState
          message={status === 404 ? "服务器不存在或已被删除" : error instanceof Error ? error.message : "加载失败"}
          onRetry={() => void refetch()}
        />
      </div>
    );
  }

  const status = serverTone(server.connection_status);

  const handleDelete = () => {
    const ok = window.confirm(`删除服务器「${server.name}」？\n\n仅移除控制台记录，不影响该服务器本身。`);
    if (!ok) return;
    del.mutate(server.id, {
      onSuccess: () => {
        toast("已删除", "ok");
        navigate("/", { replace: true });
      },
      onError: (err) => toast(err instanceof Error ? err.message : "删除失败", "danger"),
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-h1 text-text">{server.name}</h1>
            <StatusBadge tone={status.tone} label={status.label} />
          </div>
          <div className="mt-1 font-mono text-mono-sm text-text-muted">
            {server.ssh_user}@{server.host}:{server.port}
            <span className="ml-2 text-text-faint">心跳 {formatRelative(server.last_heartbeat)}</span>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <Button
            variant="secondary"
            onClick={() =>
              test.mutate(server.id, {
                onSuccess: () => toast("连接正常", "ok"),
                onError: (err) => toast(err instanceof Error ? err.message : "连接失败", "danger"),
              })
            }
            loading={test.isPending}
          >
            测试连接
          </Button>
          <Button variant="ghost" className="text-danger hover:text-danger" onClick={handleDelete} loading={del.isPending}>
            删除
          </Button>
        </div>
      </div>

      <nav className="flex gap-1 overflow-x-auto border-b border-border" aria-label="服务器功能">
        {TABS.map((t) => (
          <NavLink
            key={t.to || "overview"}
            to={t.to ? `/servers/${server.id}/${t.to}` : `/servers/${server.id}`}
            end={t.end}
            className={({ isActive }) =>
              cn(
                "relative whitespace-nowrap px-3 py-2 text-body transition-colors duration-ui ease-ui",
                isActive
                  ? "text-text before:absolute before:inset-x-2 before:bottom-0 before:h-0.5 before:rounded-full before:bg-accent"
                  : "text-text-muted hover:text-text",
              )
            }
          >
            {t.label}
          </NavLink>
        ))}
      </nav>

      <Outlet context={{ server }} />

      {server.tags ? (
        <p className="text-caption text-text-faint">
          标签：<span className="text-text-muted">{server.tags}</span>
        </p>
      ) : null}

      {server.connection_status === "offline" ? (
        <div className="rounded-card border border-border bg-surface-1">
          <EmptyState
            title="该服务器当前离线"
            description="采集任务连续失败已判定离线。请检查网络、SSH 端口与密钥是否仍然有效，然后点「测试连接」。"
          />
        </div>
      ) : null}
    </div>
  );
}
