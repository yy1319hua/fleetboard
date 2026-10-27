import { currentAccessToken, withQuery } from "@/lib/api";

/**
 * 分片上传 + 断点续传（会话内）。
 *
 * 设计：
 * - 按 chunkSize 切片，逐块 POST 到 /files/upload?path=&offset=（后端 offset>0 时续写不截断）。
 * - 每块失败自动重试（最多 3 次，指数退避），从失败块的 offset 继续，已传部分不重传。
 * - 单块进度通过 XHR upload.onprogress 上报，总进度 = 已完成字节 + 当前块已发送字节。
 */
const DEFAULT_CHUNK = 4 * 1024 * 1024; // 4 MiB

export interface UploadProgress {
  sent: number;
  total: number;
  chunkIndex: number;
  chunkCount: number;
}

export interface UploadOptions {
  serverID: number;
  file: File;
  remotePath: string;
  chunkSize?: number;
  signal?: AbortSignal;
  onProgress?: (p: UploadProgress) => void;
}

export async function uploadFileChunked(opts: UploadOptions): Promise<void> {
  const { serverID, file, remotePath, signal } = opts;
  const chunkSize = opts.chunkSize ?? DEFAULT_CHUNK;
  const total = file.size;
  const chunkCount = Math.max(1, Math.ceil(total / chunkSize));

  const url = withQuery(`/api/servers/${serverID}/files/upload`, { path: remotePath });

  let offset = 0;
  let chunkIndex = 0;
  while (offset < total) {
    if (signal?.aborted) throw new DOMException("上传已取消", "AbortError");

    const end = Math.min(offset + chunkSize, total);
    const blob = file.slice(offset, end);
    const baseOffset = offset;

    await sendChunkWithRetry(url, blob, baseOffset, signal, (loadedInChunk) => {
      opts.onProgress?.({
        sent: baseOffset + loadedInChunk,
        total,
        chunkIndex,
        chunkCount,
      });
    });

    offset = end;
    chunkIndex += 1;
    opts.onProgress?.({ sent: offset, total, chunkIndex, chunkCount });
  }

  // 空文件：仍要创建目标文件
  if (total === 0) {
    await sendChunkWithRetry(url, new Blob([]), 0, signal, () => {});
    opts.onProgress?.({ sent: 0, total: 0, chunkIndex: 1, chunkCount: 1 });
  }
}

async function sendChunkWithRetry(
  url: string,
  blob: Blob,
  offset: number,
  signal: AbortSignal | undefined,
  onChunkProgress: (loaded: number) => void,
): Promise<void> {
  const maxAttempts = 3;
  let lastErr: unknown = null;

  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await sendChunk(url, blob, offset, signal, onChunkProgress);
      return;
    } catch (err) {
      lastErr = err;
      if (err instanceof DOMException && err.name === "AbortError") throw err;
      if (attempt === maxAttempts) break;
      await new Promise((r) => setTimeout(r, 400 * 2 ** (attempt - 1)));
    }
  }
  throw lastErr instanceof Error ? lastErr : new Error("分片上传失败");
}

function sendChunk(
  url: string,
  blob: Blob,
  offset: number,
  signal: AbortSignal | undefined,
  onChunkProgress: (loaded: number) => void,
): Promise<void> {
  return new Promise((resolve, reject) => {
    // url 已含 ?path=...，此处用 URL 追加 offset，避免覆盖已有查询参数
    const u = new URL(url, window.location.origin);
    u.searchParams.set("offset", String(offset));

    const xhr = new XMLHttpRequest();
    xhr.open("POST", u.toString());
    xhr.setRequestHeader("Content-Type", "application/octet-stream");

    const token = currentAccessToken();
    if (token) xhr.setRequestHeader("Authorization", `Bearer ${token}`);

    xhr.upload.onprogress = (e) => {
      if (e.lengthComputable) onChunkProgress(e.loaded);
    };
    xhr.onload = () => {
      if (xhr.status >= 200 && xhr.status < 300) {
        resolve();
        return;
      }
      let msg = `上传失败（HTTP ${xhr.status}）`;
      try {
        const body = JSON.parse(xhr.responseText) as { msg?: string };
        if (body.msg) msg = body.msg;
      } catch {
        // 保留默认文案
      }
      reject(new Error(msg));
    };
    xhr.onerror = () => reject(new Error("网络错误，上传中断"));
    xhr.onabort = () => reject(new DOMException("上传已取消", "AbortError"));

    signal?.addEventListener("abort", () => xhr.abort(), { once: true });
    xhr.send(blob);
  });
}
