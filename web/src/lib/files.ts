import { apiDelete, apiGet, apiPost, apiPut, currentAccessToken, withQuery } from "@/lib/api";
import type { FileEntry } from "@/lib/types";

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

/** 下载：带 Authorization 头取回 Blob 再触发浏览器保存（不把 token 放进 URL）。 */
export async function downloadFile(serverID: number, path: string, onProgress?: (received: number, total: number) => void) {
  const url = withQuery(`/api/servers/${serverID}/files/download`, { path });

  const access = currentAccessToken();
  const res = await fetch(url, { headers: access ? { Authorization: `Bearer ${access}` } : {} });
  if (!res.ok) {
    throw new Error(res.status === 404 ? "文件不存在" : `下载失败（HTTP ${res.status}）`);
  }

  const total = Number(res.headers.get("Content-Length") ?? 0);
  if (!res.body || !onProgress) {
    return await res.blob();
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
  return new Blob(chunks as BlobPart[]);
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
