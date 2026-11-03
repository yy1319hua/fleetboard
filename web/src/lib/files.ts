import { apiDelete, apiGet, apiPost, apiPut, currentAccessToken, withQuery } from "@/lib/api";
import type { FileEntry } from "@/lib/types";

/** 大文件阈值：超过它先确认，避免把整个文件读进标签页内存。 */
const LARGE_FILE_BYTES = 100 * 1024 * 1024;

export interface ListResult {
  entries: FileEntry[];
  total: number;
  offset: number;
  limit: number;
}

export function listFiles(
  serverID: number,
  dir: string,
  opts: { sort?: string; order?: "asc" | "desc"; offset?: number; limit?: number } = {},
) {
  return apiGet<ListResult>(
    withQuery(`/api/servers/${serverID}/files`, {
      path: dir,
      sort: opts.sort ?? "name",
      order: opts.order ?? "asc",
      offset: opts.offset ?? 0,
      limit: opts.limit ?? 500,
    }),
  );
}

export function statFile(serverID: number, path: string) {
  return apiGet<FileEntry>(withQuery(`/api/servers/${serverID}/files/stat`, { path }));
}

export function readText(serverID: number, path: string) {
  return apiGet<{ path: string; content: string; size: number }>(
    withQuery(`/api/servers/${serverID}/files/content`, { path }),
  );
}

export function writeText(serverID: number, path: string, content: string) {
  return apiPut<{ path: string; size: number }>(`/api/servers/${serverID}/files/content`, { path, content });
}

export function renameFile(serverID: number, from: string, to: string) {
  return apiPost<{ from: string; to: string }>(`/api/servers/${serverID}/files/rename`, { from, to });
}

export function copyFile(serverID: number, from: string, to: string) {
  return apiPost<{ from: string; to: string }>(`/api/servers/${serverID}/files/copy`, { from, to });
}

export function deleteFile(serverID: number, path: string) {
  return apiDelete<{ deleted: string }>(withQuery(`/api/servers/${serverID}/files`, { path }));
}

/**
 * 文件系统访问 API 的最小类型声明。
 *
 * 不用 lib.dom 里的 FileSystemFileHandle：TS 版本不同，`showSaveFilePicker`
 * 有时不在标准库里，直接引用会编译失败。这里只声明真正用到的三个方法。
 */
interface SaveHandle {
  createWritable: () => Promise<{
    write: (chunk: BufferSource) => Promise<void>;
    close: () => Promise<void>;
    abort: () => Promise<void>;
  }>;
}
type SavePicker = (opts?: { suggestedName?: string }) => Promise<SaveHandle>;

function getSavePicker(): SavePicker | undefined {
  const w = window as unknown as { showSaveFilePicker?: SavePicker };
  return typeof w.showSaveFilePicker === "function" ? w.showSaveFilePicker.bind(window) : undefined;
}

function isAbortError(e: unknown): boolean {
  return e instanceof DOMException && (e.name === "AbortError" || e.name === "NotAllowedError");
}

export interface DownloadResult {
  /** true = 已由浏览器直接写入用户选择的文件，调用方不要再拼 Blob。 */
  savedToDisk: boolean;
  /** 用户在保存对话框里点了取消：既不报错也不提示，静默结束。 */
  cancelled: boolean;
  bytes: number;
  /** savedToDisk 为 false 时由调用方用 saveBlob 触发保存。 */
  blob?: Blob;
}

/** 把响应体逐块写进文件流，全程只占一个 chunk 的内存。 */
async function pumpToWritable(
  res: Response,
  writable: { write: (chunk: BufferSource) => Promise<void> },
  total: number,
  onProgress?: (received: number, total: number) => void,
): Promise<number> {
  if (!res.body) {
    const buf = new Uint8Array(await res.arrayBuffer());
    await writable.write(buf);
    onProgress?.(buf.byteLength, total || buf.byteLength);
    return buf.byteLength;
  }

  const reader = res.body.getReader();
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    await writable.write(value);
    received += value.byteLength;
    onProgress?.(received, total);
  }
  return received;
}

/**
 * 下载：带 Authorization 头取回文件（不把 token 放进 URL）。
 *
 * 首选「边下边写盘」（File System Access API）：文件多大都只占一个 chunk 的
 * 内存，几百 MB 的镜像包也不会把标签页撑爆，同时用户能实时看到进度。
 *
 * 浏览器不支持时退回 Blob：此时整个文件会进标签页内存，所以超过阈值先确认。
 */
export async function downloadFile(
  serverID: number,
  path: string,
  filename: string,
  onProgress?: (received: number, total: number) => void,
): Promise<DownloadResult> {
  const url = withQuery(`/api/servers/${serverID}/files/download`, { path });
  const access = currentAccessToken();
  const res = await fetch(url, { headers: access ? { Authorization: `Bearer ${access}` } : {} });
  if (!res.ok) {
    throw new Error(res.status === 404 ? "文件不存在" : `下载失败（HTTP ${res.status}）`);
  }

  const total = Number(res.headers.get("Content-Length") ?? 0);

  const picker = getSavePicker();
  if (picker) {
    let writable: Awaited<ReturnType<SaveHandle["createWritable"]>> | undefined;
    try {
      const handle = await picker({ suggestedName: filename });
      writable = await handle.createWritable();
    } catch (e) {
      // 用户取消：静默返回，不要弹「下载失败」。
      if (isAbortError(e)) return { savedToDisk: false, cancelled: true, bytes: 0 };
      // 其它原因（权限策略、iframe 限制、浏览器实现差异）→ 走 Blob 退路。
      writable = undefined;
    }

    if (writable) {
      try {
        const bytes = await pumpToWritable(res, writable, total, onProgress);
        await writable.close();
        return { savedToDisk: true, cancelled: false, bytes };
      } catch (e) {
        // 只丢弃未提交的临时文件；已写入的部分不会留在用户目录里。
        await writable.abort().catch(() => undefined);
        throw e;
      }
    }
  }

  // 降级：手动累积分片会把整个文件读进内存，几百 MB 足以让标签页 OOM，
  // 所以大文件先确认，再交给浏览器原生 blob()（内核可溢写到临时文件）。
  if (total > LARGE_FILE_BYTES) {
    const proceed = window.confirm(
      `当前浏览器不支持直接写盘，该文件约 ${(total / 1024 / 1024).toFixed(1)} MB，需要先下载到内存，可能较慢。继续？`,
    );
    if (!proceed) return { savedToDisk: false, cancelled: true, bytes: 0 };
    const blob = await res.blob();
    return { savedToDisk: false, cancelled: false, bytes: blob.size, blob };
  }

  if (!res.body || !onProgress) {
    const blob = await res.blob();
    return { savedToDisk: false, cancelled: false, bytes: blob.size, blob };
  }

  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (value) {
      chunks.push(value);
      received += value.byteLength;
      onProgress(received, total);
    }
  }
  return { savedToDisk: false, cancelled: false, bytes: received, blob: new Blob(chunks as BlobPart[]) };
}

/** 触发浏览器保存。 */
export function saveBlob(blob: Blob, filename: string): void {
  const href = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = href;
  a.download = filename;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(href);
}

/** 路径工具（前端统一用 / 分隔，与后端 SFTP 一致）。 */
export function joinPath(dir: string, name: string): string {
  if (dir.endsWith("/")) return `${dir}${name}`;
  return `${dir}/${name}`;
}

export function parentPath(p: string): string {
  const clean = p.replace(/\/+$/, "");
  const idx = clean.lastIndexOf("/");
  if (idx <= 0) return "/";
  return clean.slice(0, idx);
}

/** 面包屑：/a/b/c -> [{name:"/", path:"/"}, {name:"a",...}, ...] */
export function breadcrumbs(p: string): { name: string; path: string }[] {
  const parts = p.split("/").filter(Boolean);
  const out: { name: string; path: string }[] = [{ name: "/", path: "/" }];
  let acc = "";
  for (const part of parts) {
    acc += `/${part}`;
    out.push({ name: part, path: acc });
  }
  return out;
}
