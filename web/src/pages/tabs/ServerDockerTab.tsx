import { useState } from "react";
import { useOutletContext } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { LogTerminal } from "@/components/docker/LogTerminal";
import { Button } from "@/components/ui/Button";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { StatusBadge, containerTone } from "@/components/ui/StatusBadge";
import { toast } from "@/components/ui/Toast";
import {
  containerAction,
  containerStats,
  dockerDiskUsage,
  listContainers,
  listImages,
  listNetworks,
  listVolumes,
  pruneDocker,
  pullImage,
  removeImage,
  removeVolume,
  type ContainerAction,
} from "@/lib/docker";
import { cn } from "@/lib/cn";
import type { Server } from "@/lib/types";

interface Ctx {
  server: Server;
}

type SubTab = "containers" | "images" | "networks" | "volumes";

const SUB_TABS: { key: SubTab; label: string }[] = [
  { key: "containers", label: "容器" },
  { key: "images", label: "镜像" },
  { key: "networks", label: "网络" },
  { key: "volumes", label: "数据卷" },
];

const ACTION_LABEL: Record<ContainerAction, string> = {
  start: "启动",
  stop: "停止",
  restart: "重启",
  rm: "删除",
};

export function ServerDockerTab() {
  const { server } = useOutletContext<Ctx>();
  const qc = useQueryClient();
  const [sub, setSub] = useState<SubTab>("containers");
  const [logsFor, setLogsFor] = useState<{ id: string; name: string } | null>(null);

  const containers = useQuery({
    queryKey: ["docker", server.id, "containers"],
    queryFn: () => listContainers(server.id),
    refetchInterval: 10_000,
  });

  const stats = useQuery({
    queryKey: ["docker", server.id, "stats"],
    queryFn: () => containerStats(server.id),
    refetchInterval: 15_000,
    enabled: sub === "containers",
  });

  const images = useQuery({
    queryKey: ["docker", server.id, "images"],
    queryFn: () => listImages(server.id),
    enabled: sub === "images",
  });

  const networks = useQuery({
    queryKey: ["docker", server.id, "networks"],
    queryFn: () => listNetworks(server.id),
    enabled: sub === "networks",
  });

  const volumes = useQuery({
    queryKey: ["docker", server.id, "volumes"],
    queryFn: () => listVolumes(server.id),
    enabled: sub === "volumes",
  });

  const act = useMutation({
    mutationFn: ({ cid, action }: { cid: string; action: ContainerAction }) =>
      containerAction(server.id, cid, action),
    onSuccess: (_data, vars) => {
      toast(`${ACTION_LABEL[vars.action]}成功`, "ok");
      void qc.invalidateQueries({ queryKey: ["docker", server.id] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "操作失败", "danger"),
  });

  const pull = useMutation({
    mutationFn: (ref: string) => pullImage(server.id, ref),
    onSuccess: () => {
      toast("镜像拉取完成", "ok");
      void qc.invalidateQueries({ queryKey: ["docker", server.id, "images"] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "拉取失败", "danger"),
  });

  const rmi = useMutation({
    mutationFn: (id: string) => removeImage(server.id, id),
    onSuccess: () => {
      toast("镜像已删除", "ok");
      void qc.invalidateQueries({ queryKey: ["docker", server.id, "images"] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "删除失败", "danger"),
  });

  const rmv = useMutation({
    mutationFn: (name: string) => removeVolume(server.id, name),
    onSuccess: () => {
      toast("数据卷已删除", "ok");
      void qc.invalidateQueries({ queryKey: ["docker", server.id] });
    },
    // 409 的 message 里带容器名，原样展示——用户需要知道是哪个容器在占用。
    onError: (e) => toast(e instanceof Error ? e.message : "删除失败", "danger"),
  });

  const prune = useMutation({
    // 只清「没有容器引用」的三类：悬空镜像 / 未使用卷 / 构建缓存。
    mutationFn: () => pruneDocker(server.id, ["images", "volumes", "build_cache"]),
    onSuccess: (data) => {
      const detail = data.results
        .map((r) => `${r.target}${r.reclaimed ? ` ${r.reclaimed}` : ""}`)
        .join("，");
      toast(detail ? `清理完成：${detail}` : "清理完成", "ok");
      void qc.invalidateQueries({ queryKey: ["docker", server.id] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "清理失败", "danger"),
  });

  const statsMap = new Map((stats.data ?? []).map((s) => [s.container.slice(0, 12), s]));

  const handleAction = (cid: string, name: string, action: ContainerAction) => {
    if (action === "rm") {
      const ok = window.confirm(
        `删除容器「${name}」？\n\n使用 docker rm -f，运行中的容器会被强制停止。数据卷不受影响。`,
      );
      if (!ok) return;
    }
    act.mutate({ cid, action });
  };

  const handlePull = () => {
    const ref = window.prompt("输入镜像引用，例如 nginx:1.27-alpine", "nginx:latest");
    if (!ref) return;
    pull.mutate(ref.trim());
  };

  const handleRmi = (id: string, repo: string) => {
    const ok = window.confirm(`删除镜像「${repo}」？`);
    if (!ok) return;
    rmi.mutate(id);
  };

  const handleRmv = (name: string) => {
    const ok = window.confirm(
      `删除数据卷「${name}」？\n\n卷里的数据会一起删除，无法恢复。\n` +
        `仍被容器引用（含已停止容器）时会拒绝删除，并提示是哪个容器。`,
    );
    if (!ok) return;
    rmv.mutate(name);
  };

  const handlePrune = async () => {
    try {
      const rows = await dockerDiskUsage(server.id);
      const summary = rows
        .map((r) => `${r.type}：占 ${r.size}，可回收 ${r.reclaimable || "—"}`)
        .join("\n");
      const ok = window.confirm(
        `清理 Docker 空间（只清没有容器引用的资源）\n\n${summary}\n\n` +
          `将清理：悬空镜像、未使用卷、构建缓存。这些数据删除后无法恢复，继续？`,
      );
      if (!ok) return;
      prune.mutate();
    } catch (e) {
      toast(e instanceof Error ? e.message : "读取占用失败", "danger");
    }
  };

  return (
    <div className="space-y-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-1 rounded-control border border-border bg-surface-1 p-0.5">
          {SUB_TABS.map((t) => (
            <button
              key={t.key}
              type="button"
              onClick={() => setSub(t.key)}
              className={cn(
                "min-h-11 rounded-[5px] px-3 text-body-sm transition-colors duration-ui ease-ui sm:min-h-0 sm:h-8",
                sub === t.key ? "bg-accent-soft text-text" : "text-text-muted hover:text-text",
              )}
            >
              {t.label}
            </button>
          ))}
        </div>

        <div className="flex items-center gap-2">
          {sub === "containers" ? (
            <Button size="sm" variant="secondary" onClick={() => void containers.refetch()} disabled={containers.isFetching}>
              刷新
            </Button>
          ) : null}
          {sub === "images" ? (
            <Button size="sm" variant="primary" onClick={handlePull} loading={pull.isPending}>
              拉取镜像
            </Button>
          ) : null}
          {sub === "volumes" ? (
            <>
              <Button size="sm" variant="secondary" onClick={() => void volumes.refetch()} disabled={volumes.isFetching}>
                刷新
              </Button>
              <Button size="sm" variant="primary" onClick={() => void handlePrune()} loading={prune.isPending}>
                清理空间
              </Button>
            </>
          ) : null}
        </div>
      </div>

      <div className="rounded-card border border-border bg-surface-1">
        {sub === "containers" ? (
          containers.isLoading ? (
            <SkeletonRows rows={5} cols={5} />
          ) : containers.isError ? (
            <ErrorState
              message={containers.error instanceof Error ? containers.error.message : "获取容器列表失败"}
              onRetry={() => void containers.refetch()}
            />
          ) : (containers.data ?? []).length === 0 ? (
            <EmptyState
              title="没有容器"
              description="该服务器上还没有任何容器，或当前 SSH 用户无权访问 Docker（需在 docker 组内）。"
            />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[900px] border-collapse">
                <thead className="bg-surface-2">
                  <tr className="border-b border-border">
                    <th className="px-3 py-2 text-left"><span className="eyebrow">名称</span></th>
                    <th className="px-3 py-2 text-left"><span className="eyebrow">镜像</span></th>
                    <th className="w-32 px-3 py-2 text-left"><span className="eyebrow">状态</span></th>
                    <th className="w-28 px-3 py-2 text-right"><span className="eyebrow">CPU</span></th>
                    <th className="w-32 px-3 py-2 text-right"><span className="eyebrow">内存</span></th>
                    <th className="w-[320px] px-3 py-2 text-right"><span className="eyebrow">操作</span></th>
                  </tr>
                </thead>
                <tbody>
                  {(containers.data ?? []).map((c) => {
                    const tone = containerTone(c.state);
                    const st = statsMap.get(c.id.slice(0, 12));
                    const running = c.state === "running";
                    return (
                      <tr key={c.id} className="h-10 border-b border-border last:border-0 hover:bg-surface-3">
                        <td className="px-3">
                          <div className="truncate font-mono text-mono text-text">{c.name}</div>
                          <div className="truncate font-mono text-caption text-text-faint">{c.id.slice(0, 12)}</div>
                        </td>
                        <td className="px-3">
                          <span className="block max-w-[220px] truncate font-mono text-mono-sm text-text-muted">{c.image}</span>
                        </td>
                        <td className="px-3"><StatusBadge tone={tone.tone} label={tone.label} /></td>
                        <td className="tabular whitespace-nowrap px-3 text-right font-mono text-mono-sm text-text-muted">
                          {running ? (st?.cpu_perc ?? "—") : "—"}
                        </td>
                        <td className="tabular whitespace-nowrap px-3 text-right font-mono text-mono-sm text-text-muted">
                          {running ? (st?.mem_perc ?? "—") : "—"}
                        </td>
                        <td className="px-3">
                          <div className="flex flex-nowrap justify-end gap-1">
                            <Button size="sm" variant="ghost" onClick={() => setLogsFor({ id: c.id, name: c.name })}>
                              日志
                            </Button>
                            {running ? (
                              <>
                                <Button size="sm" variant="ghost" onClick={() => handleAction(c.id, c.name, "restart")}>
                                  重启
                                </Button>
                                <Button size="sm" variant="ghost" onClick={() => handleAction(c.id, c.name, "stop")}>
                                  停止
                                </Button>
                              </>
                            ) : (
                              <Button size="sm" variant="ghost" onClick={() => handleAction(c.id, c.name, "start")}>
                                启动
                              </Button>
                            )}
                            <Button
                              size="sm"
                              variant="ghost"
                              className="text-danger hover:text-danger"
                              onClick={() => handleAction(c.id, c.name, "rm")}
                            >
                              删除
                            </Button>
                          </div>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )
        ) : null}

        {sub === "images" ? (
          images.isLoading ? (
            <SkeletonRows rows={5} cols={4} />
          ) : images.isError ? (
            <ErrorState
              message={images.error instanceof Error ? images.error.message : "获取镜像失败"}
              onRetry={() => void images.refetch()}
            />
          ) : (images.data ?? []).length === 0 ? (
            <EmptyState title="没有镜像" description="可点右上角「拉取镜像」按引用拉取。" />
          ) : (
            <div className="overflow-x-auto">
              <table className="w-full min-w-[760px] border-collapse">
                <thead className="bg-surface-2">
                  <tr className="border-b border-border">
                    <th className="px-3 py-2 text-left"><span className="eyebrow">仓库</span></th>
                    <th className="w-28 px-3 py-2 text-left"><span className="eyebrow">标签</span></th>
                    <th className="w-24 px-3 py-2 text-right"><span className="eyebrow">大小</span></th>
                    <th className="w-32 px-3 py-2 text-left"><span className="eyebrow">创建</span></th>
                    <th className="w-24 px-3 py-2 text-right"><span className="eyebrow">操作</span></th>
                  </tr>
                </thead>
                <tbody>
                  {(images.data ?? []).map((img) => (
                    <tr key={img.id} className="h-10 border-b border-border last:border-0 hover:bg-surface-3">
                      <td className="px-3">
                        <span className="block truncate font-mono text-mono text-text">{img.repository}</span>
                        <span className="font-mono text-caption text-text-faint">{img.id.replace("sha256:", "").slice(0, 12)}</span>
                      </td>
                      <td className="px-3 font-mono text-mono-sm text-text-muted">{img.tag}</td>
                      <td className="tabular px-3 text-right font-mono text-mono-sm text-text-muted">{img.size}</td>
                      <td className="px-3 font-mono text-mono-sm text-text-faint">{img.created_since}</td>
                      <td className="px-3 text-right">
                        <Button
                          size="sm"
                          variant="ghost"
                          className="text-danger hover:text-danger"
                          onClick={() => handleRmi(img.id, `${img.repository}:${img.tag}`)}
                        >
                          删除
                        </Button>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )
        ) : null}

        {sub === "networks" ? (
          networks.isLoading ? (
            <SkeletonRows rows={4} cols={3} />
          ) : networks.isError ? (
            <ErrorState
              message={networks.error instanceof Error ? networks.error.message : "获取网络失败"}
              onRetry={() => void networks.refetch()}
            />
          ) : (
            <ul className="divide-y divide-border">
              {(networks.data ?? []).map((n) => (
                <li key={n.id} className="flex items-center justify-between gap-3 px-3 py-2">
                  <span className="truncate font-mono text-mono text-text">{n.name}</span>
                  <span className="shrink-0 font-mono text-mono-sm text-text-faint">
                    {n.driver} · {n.scope}
                  </span>
                </li>
              ))}
            </ul>
          )
        ) : null}

        {sub === "volumes" ? (
          volumes.isLoading ? (
            <SkeletonRows rows={4} cols={3} />
          ) : volumes.isError ? (
            <ErrorState
              message={volumes.error instanceof Error ? volumes.error.message : "获取数据卷失败"}
              onRetry={() => void volumes.refetch()}
            />
          ) : (
            <ul className="divide-y divide-border">
              {(volumes.data ?? []).map((v) => (
                <li key={v.name} className="flex items-center justify-between gap-3 px-3 py-2">
                  <div className="min-w-0">
                    <div className="truncate font-mono text-mono text-text">{v.name}</div>
                    <div className="truncate font-mono text-caption text-text-faint">
                      {v.driver} · {v.mountpoint}
                    </div>
                  </div>
                  <Button size="sm" variant="ghost" onClick={() => handleRmv(v.name)}>
                    删除
                  </Button>
                </li>
              ))}
            </ul>
          )
        ) : null}
      </div>

      {logsFor ? (
        <div className="fixed inset-0 z-40 flex justify-end">
          <div className="absolute inset-0 bg-[#05070a]/60" onClick={() => setLogsFor(null)} aria-hidden="true" />
          <div
            role="dialog"
            aria-modal="true"
            aria-label={`容器日志 ${logsFor.name}`}
            className="relative flex h-full w-full flex-col border-l border-border bg-surface-1 shadow-modal sm:w-[720px]"
          >
            <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-2">
              <span className="eyebrow">容器日志</span>
              <Button size="sm" variant="ghost" onClick={() => setLogsFor(null)}>
                关闭
              </Button>
            </div>
            <LogTerminal serverID={server.id} cid={logsFor.id} title={`${logsFor.name}（${logsFor.id.slice(0, 12)}）`} />
          </div>
        </div>
      ) : null}
    </div>
  );
}
