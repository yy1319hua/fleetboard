import { useMemo, useRef, useState } from "react";
import { Link, useOutletContext } from "react-router-dom";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { IconFolder, IconTerminal } from "@/components/icons";
import { Button } from "@/components/ui/Button";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { toast } from "@/components/ui/Toast";
import {
  breadcrumbs,
  copyFile,
  deleteFile,
  downloadFile,
  joinPath,
  listFiles,
  parentPath,
  renameFile,
  saveBlob,
  statFile,
} from "@/lib/files";
import { formatBytes, formatDateTime } from "@/lib/format";
import { uploadFileChunked, type UploadProgress } from "@/lib/upload";
import { cn } from "@/lib/cn";
import type { FileEntry, Server } from "@/lib/types";

import { EditorDrawer } from "@/components/files/EditorDrawer";

interface Ctx {
  server: Server;
}

type SortField = "name" | "size" | "mod_time";

interface UploadItem {
  id: number;
  name: string;
  progress: UploadProgress;
  /**
   * `verifying` 是「分片全发完了，正在比对服务端字节数」的中间态。
   *
   * 必须有这个态，不能发完就报「完成」：后端 `/files/upload` 在只写入一部分时
   * 同样返回 200（磁盘满、连接中断都会这样），所以 HTTP 成功不等于文件完整。
   * 如果直接置 done，用户会以为传好了，等到某天要用这个文件时才发现是残缺的。
   */
  status: "uploading" | "verifying" | "done" | "error";
  error?: string;
  abort: AbortController;
}

/** 文件管理：目录浏览 + 上传（分片续传）+ 下载 + 在线编辑 + 增删改。 */
export function ServerFilesTab() {
  const { server } = useOutletContext<Ctx>();
  const qc = useQueryClient();

  const [dir, setDir] = useState("/");
  const [sort, setSort] = useState<SortField>("name");
  const [order, setOrder] = useState<"asc" | "desc">("asc");
  const [editing, setEditing] = useState<string | null>(null);
  const [uploads, setUploads] = useState<UploadItem[]>([]);
  const fileInput = useRef<HTMLInputElement>(null);

  const queryKey = ["files", server.id, dir, sort, order] as const;
  const { data, isLoading, isError, error, refetch, isFetching } = useQuery({
    queryKey,
    queryFn: () => listFiles(server.id, dir, { sort, order, limit: 500 }),
  });

  const entries = data?.entries ?? [];
  const crumbs = useMemo(() => breadcrumbs(dir), [dir]);

  const invalidate = () => {
    void qc.invalidateQueries({ queryKey: ["files", server.id] });
  };

  const del = useMutation({
    mutationFn: (path: string) => deleteFile(server.id, path),
    onSuccess: () => {
      toast("已删除", "ok");
      invalidate();
    },
    onError: (e) => toast(e instanceof Error ? e.message : "删除失败", "danger"),
  });

  const rename = useMutation({
    mutationFn: ({ from, to }: { from: string; to: string }) => renameFile(server.id, from, to),
    onSuccess: () => {
      toast("已重命名", "ok");
      invalidate();
    },
    onError: (e) => toast(e instanceof Error ? e.message : "重命名失败", "danger"),
  });

  const copy = useMutation({
    mutationFn: ({ from, to }: { from: string; to: string }) => copyFile(server.id, from, to),
    onSuccess: () => {
      toast("已复制", "ok");
      invalidate();
    },
    onError: (e) => toast(e instanceof Error ? e.message : "复制失败", "danger"),
  });

  const toggleSort = (field: SortField) => {
    if (sort === field) {
      setOrder((o) => (o === "asc" ? "desc" : "asc"));
      return;
    }
    setSort(field);
    setOrder("asc");
  };

  const handleDownload = async (entry: FileEntry) => {
    try {
      const blob = await downloadFile(server.id, entry.path);
      saveBlob(blob, entry.name);
      toast("已开始下载", "ok");
    } catch (e) {
      toast(e instanceof Error ? e.message : "下载失败", "danger");
    }
  };

  const handleRename = (entry: FileEntry) => {
    const next = window.prompt("重命名为（可含路径）", entry.name);
    if (!next || next === entry.name) return;
    const target = next.includes("/") ? next : joinPath(dir, next);
    rename.mutate({ from: entry.path, to: target });
  };

  const handleCopy = (entry: FileEntry) => {
    const next = window.prompt("复制到（完整目标路径）", `${entry.path}.copy`);
    if (!next) return;
    copy.mutate({ from: entry.path, to: next });
  };

  const handleDelete = (entry: FileEntry) => {
    const ok = window.confirm(
      `删除「${entry.name}」？${entry.dir ? "\n\n这是目录，将递归删除其中全部内容。" : ""}`,
    );
    if (!ok) return;
    del.mutate(entry.path);
  };

  const handlePickFiles = () => fileInput.current?.click();

  const handleUpload = async (files: FileList | null) => {
    if (!files || files.length === 0) return;

    for (const file of Array.from(files)) {
      const abort = new AbortController();
      const item: UploadItem = {
        id: Date.now() + Math.random(),
        name: file.name,
        progress: { sent: 0, total: file.size, chunkIndex: 0, chunkCount: 1 },
        status: "uploading",
        abort,
      };
      setUploads((prev) => [...prev, item]);

      const update = (patch: Partial<UploadItem>) =>
        setUploads((prev) => prev.map((u) => (u.id === item.id ? { ...u, ...patch } : u)));

      const remotePath = joinPath(dir, file.name);

      try {
        await uploadFileChunked({
          serverID: server.id,
          file,
          remotePath,
          signal: abort.signal,
          onProgress: (p) => update({ progress: p }),
        });

        // 分片全部发完 ≠ 文件写全。后端上传接口在只写入一部分时也返回 200，
        // 唯一可信的判据是服务端 stat 出来的字节数（与 App 侧同一套判据）。
        update({ status: "verifying" });
        let remoteSize: number;
        try {
          const st = await statFile(server.id, remotePath);
          remoteSize = st.size;
        } catch {
          // 校验本身失败时不能当成功：宁可让用户回列表里自己确认，
          // 也不能报「完成」——猜错的代价是用户以为文件好好的。
          update({ status: "error", error: "已发送，但无法校验完整性" });
          invalidate();
          continue;
        }

        if (remoteSize === file.size) {
          update({ status: "done" });
        } else {
          const short = remoteSize < file.size;
          update({
            status: "error",
            error: `服务端 ${formatBytes(remoteSize)} ≠ 本地 ${formatBytes(file.size)}${
              short ? "，可能磁盘已满" : ""
            }`,
          });
        }
        // 无论成没成都要刷新列表：失败的文件已经躺在远端了，
        // 不刷出来用户就看不到、也没法手动删掉这个残缺文件。
        invalidate();
      } catch (e) {
        const aborted = e instanceof DOMException && e.name === "AbortError";
        update({ status: "error", error: aborted ? "已取消" : e instanceof Error ? e.message : "上传失败" });
        // 取消/中断同样会留下已写入的部分，列表要刷新才能看见。
        if (aborted) invalidate();
      }
    }

    if (fileInput.current) fileInput.current.value = "";
  };

  const th = (label: string, field?: SortField, className?: string) => (
    <th
      className={cn("px-3 py-2 text-left font-semibold", field ? "cursor-pointer select-none hover:text-text" : "", className)}
      onClick={field ? () => toggleSort(field) : undefined}
      aria-sort={field && sort === field ? (order === "asc" ? "ascending" : "descending") : undefined}
    >
      <span className="eyebrow inline-flex items-center gap-1">
        {label}
        {field && sort === field ? <span aria-hidden="true">{order === "asc" ? "↑" : "↓"}</span> : null}
      </span>
    </th>
  );

  return (
    <div className="space-y-3">
      {/* 工具栏 */}
      <div className="flex flex-wrap items-center justify-between gap-2">
        <nav className="flex min-w-0 flex-wrap items-center gap-1 font-mono text-mono-sm" aria-label="路径">
          {crumbs.map((c, i) => (
            <span key={c.path} className="flex items-center gap-1">
              {i > 0 ? <span className="text-text-faint">/</span> : null}
              <button
                type="button"
                onClick={() => setDir(c.path)}
                className={cn(
                  "rounded px-1 py-0.5 hover:bg-surface-2",
                  i === crumbs.length - 1 ? "text-text" : "text-text-muted hover:text-text",
                )}
              >
                {c.name === "/" ? "root" : c.name}
              </button>
            </span>
          ))}
        </nav>

        <div className="flex items-center gap-2">
          {dir !== "/" ? (
            <Button size="sm" variant="ghost" onClick={() => setDir(parentPath(dir))}>
              上一级
            </Button>
          ) : null}
          <Button size="sm" variant="secondary" onClick={() => void refetch()} disabled={isFetching}>
            刷新
          </Button>
          <Button size="sm" variant="primary" onClick={handlePickFiles}>
            上传
          </Button>
          <input
            ref={fileInput}
            type="file"
            multiple
            className="hidden"
            onChange={(e) => void handleUpload(e.target.files)}
          />
        </div>
      </div>

      {/* 上传进度 */}
      {uploads.length > 0 ? (
        <div className="space-y-1.5 rounded-card border border-border bg-surface-1 px-3 py-2.5">
          {uploads.map((u) => {
            const pct = u.progress.total > 0 ? Math.round((u.progress.sent / u.progress.total) * 100) : 100;
            return (
              <div key={u.id} className="flex items-center gap-3">
                <span className="min-w-0 flex-1 truncate font-mono text-mono-sm text-text-muted">{u.name}</span>
                <span className="tabular text-caption text-text-faint">
                  {u.status === "done"
                    ? "完成"
                    : u.status === "verifying"
                      ? "校验中…"
                      : u.status === "error"
                        ? (u.error ?? "失败")
                        : `${pct}%`}
                </span>
                {u.status === "uploading" ? (
                  <button
                    type="button"
                    className="text-caption text-danger hover:underline"
                    onClick={() => u.abort.abort()}
                  >
                    取消
                  </button>
                ) : null}
                <div className="h-1 w-24 overflow-hidden rounded-pill bg-surface-3">
                  <div
                    className={cn(
                      "h-full rounded-pill",
                      u.status === "error" ? "bg-danger" : u.status === "done" ? "bg-ok" : "bg-accent",
                    )}
                    style={{ width: `${pct}%` }}
                  />
                </div>
                <button
                  type="button"
                  className="text-caption text-text-faint hover:text-text"
                  onClick={() => setUploads((prev) => prev.filter((x) => x.id !== u.id))}
                >
                  移除
                </button>
              </div>
            );
          })}
        </div>
      ) : null}

      {/* 列表 */}
      <div className="rounded-card border border-border bg-surface-1">
        {isLoading ? (
          <SkeletonRows rows={6} cols={4} />
        ) : isError ? (
          <ErrorState message={error instanceof Error ? error.message : "加载失败"} onRetry={() => void refetch()} />
        ) : entries.length === 0 ? (
          <EmptyState title="空目录" description="此目录下没有文件，或当前 SSH 用户无读取权限。" />
        ) : (
          <>
            {/* 桌面表格 */}
            <div className="hidden overflow-x-auto md:block">
              <table className="w-full min-w-[880px] border-collapse">
                <thead className="bg-surface-2">
                  <tr className="border-b border-border">
                    {th("名称", "name")}
                    {th("大小", "size", "w-24 text-right")}
                    <th className="w-32 whitespace-nowrap px-3 py-2 text-left">
                      <span className="eyebrow">权限</span>
                    </th>
                    {th("修改时间", "mod_time", "w-[172px] whitespace-nowrap")}
                    <th className="w-[300px] whitespace-nowrap px-3 py-2 text-right">
                      <span className="eyebrow">操作</span>
                    </th>
                  </tr>
                </thead>
                <tbody>
                  {entries.map((e) => (
                    <tr key={e.path} className="h-10 border-b border-border last:border-0 hover:bg-surface-3">
                      <td className="px-3">
                        <button
                          type="button"
                          onClick={() => (e.dir ? setDir(e.path) : setEditing(e.path))}
                          className="flex min-w-0 items-center gap-2 text-left text-body text-text hover:text-accent"
                        >
                          {e.dir ? <IconFolder className="text-accent" /> : <IconTerminal className="text-text-faint" />}
                          <span className="truncate font-mono text-mono">{e.name}</span>
                        </button>
                      </td>
                      <td className="tabular whitespace-nowrap px-3 text-right font-mono text-mono-sm text-text-muted">
                        {e.dir ? "—" : formatBytes(e.size)}
                      </td>
                      <td className="whitespace-nowrap px-3 font-mono text-mono-sm text-text-faint">{e.mode}</td>
                      <td className="tabular whitespace-nowrap px-3 font-mono text-mono-sm text-text-muted">
                        {formatDateTime(e.mod_time)}
                      </td>
                      <td className="px-3 text-right">
                        <div className="flex flex-nowrap justify-end gap-1">
                          {!e.dir ? (
                            <>
                              <Button size="sm" variant="ghost" onClick={() => void handleDownload(e)}>
                                下载
                              </Button>
                              <Button size="sm" variant="ghost" onClick={() => setEditing(e.path)}>
                                编辑
                              </Button>
                            </>
                          ) : null}
                          <Button size="sm" variant="ghost" onClick={() => handleRename(e)}>
                            改名
                          </Button>
                          <Button size="sm" variant="ghost" onClick={() => handleCopy(e)}>
                            复制
                          </Button>
                          <Button
                            size="sm"
                            variant="ghost"
                            className="text-danger hover:text-danger"
                            onClick={() => handleDelete(e)}
                          >
                            删除
                          </Button>
                        </div>
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {/* 移动卡片列表 */}
            <ul className="divide-y divide-border md:hidden">
              {entries.map((e) => (
                <li key={e.path} className="px-3 py-2.5">
                  <div className="flex items-start justify-between gap-2">
                    <button
                      type="button"
                      onClick={() => (e.dir ? setDir(e.path) : setEditing(e.path))}
                      className="flex min-w-0 items-center gap-2 text-left"
                    >
                      {e.dir ? <IconFolder className="text-accent" /> : <IconTerminal className="text-text-faint" />}
                      <span className="min-w-0">
                        <span className="block truncate font-mono text-mono text-text">{e.name}</span>
                        <span className="tabular block text-caption text-text-faint">
                          {e.dir ? "目录" : formatBytes(e.size)} · {formatDateTime(e.mod_time)}
                        </span>
                      </span>
                    </button>
                  </div>
                  <div className="mt-1.5 flex flex-wrap gap-1">
                    {!e.dir ? (
                      <>
                        <Button size="sm" variant="ghost" onClick={() => void handleDownload(e)}>
                          下载
                        </Button>
                        <Button size="sm" variant="ghost" onClick={() => setEditing(e.path)}>
                          编辑
                        </Button>
                      </>
                    ) : null}
                    <Button size="sm" variant="ghost" onClick={() => handleRename(e)}>
                      改名
                    </Button>
                    <Button size="sm" variant="ghost" className="text-danger hover:text-danger" onClick={() => handleDelete(e)}>
                      删除
                    </Button>
                  </div>
                </li>
              ))}
            </ul>
          </>
        )}
      </div>

      <p className="text-caption text-text-faint">
        共 {data?.total ?? 0} 项 · 在线编辑上限 1 MiB · 上传按 4 MiB 分片，失败自动从断点续传 ·{" "}
        <Link to={`/servers/${server.id}/compose`} className="text-accent hover:underline">
          管理 Compose
        </Link>
      </p>

      {editing ? (
        <EditorDrawer
          serverID={server.id}
          path={editing}
          onClose={() => setEditing(null)}
          onSaved={() => {
            invalidate();
            setEditing(null);
          }}
        />
      ) : null}
    </div>
  );
}
