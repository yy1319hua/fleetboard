/**
 * 软件包更新（M6.9）：SSE 流式进度客户端。
 *
 * 后端契约（internal/api/packages_handlers.go）：
 * - POST /api/servers/:id/packages/update → text/event-stream
 * - 帧：`data: {json}\n\n`
 *   - {event:"started", message}
 *   - {event:"line", line}
 *   - {event:"done", ok, canceled?, error?}
 * - 取消：客户端 abort → 后端向远端 apt 发 SIGINT。
 *
 * 用 fetch + ReadableStream 而非 EventSource：POST + Authorization 头，
 * token 不进 URL（与 WS 票据方案同理）。
 */

export interface PackageUpdateHooks {
  onStarted?: (message: string) => void;
  onLine?: (line: string) => void;
  /** done 帧：ok=true 成功；canceled=true 用户取消；失败时 error 为统一文案。 */
  onDone: (result: { ok: boolean; canceled?: boolean; error?: string }) => void;
}

interface SseFrame {
  event?: string;
  message?: string;
  line?: string;
  ok?: boolean;
  canceled?: boolean;
  error?: string;
}

/** 发起更新并逐帧回调；返回 abort 函数（幂等）。 */
export function streamPackageUpdate(
  serverID: number,
  hooks: PackageUpdateHooks,
): { abort: () => void; done: Promise<void> } {
  const ctrl = new AbortController();
  let aborted = false;
  let finished = false;
  // done 只回调一次：abort 与服务端 done 帧可能竞态
  const finish = (r: { ok: boolean; canceled?: boolean; error?: string }) => {
    if (finished) return;
    finished = true;
    hooks.onDone(r);
  };

  const done = (async () => {
    const { currentAccessToken } = await import("./api");
    try {
      const res = await fetch(`/api/servers/${serverID}/packages/update`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(currentAccessToken() ? { Authorization: `Bearer ${currentAccessToken()}` } : {}),
        },
        signal: ctrl.signal,
      });

      if (res.status === 401) {
        finish({ ok: false, error: "登录已过期，请重新登录" });
        return;
      }
      // 流开始前的错误（如连接失败 502）：统一 JSON 响应
      if (!res.ok || !res.body) {
        let msg = `请求失败（HTTP ${res.status}）`;
        try {
          const body = (await res.json()) as { msg?: string };
          if (body?.msg) msg = body.msg;
        } catch {
          /* 非 JSON 错误体，用默认文案 */
        }
        finish({ ok: false, error: msg });
        return;
      }

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "";

      const handleFrame = (raw: string) => {
        const data = raw.startsWith("data: ") ? raw.slice(6) : raw.replace(/^data:/, "");
        if (!data.trim()) return;
        let frame: SseFrame;
        try {
          frame = JSON.parse(data) as SseFrame;
        } catch {
          return; // 坏帧忽略，不中断流
        }
        switch (frame.event) {
          case "started":
            hooks.onStarted?.(frame.message ?? "开始更新软件包");
            break;
          case "line":
            if (frame.line !== undefined) hooks.onLine?.(frame.line);
            break;
          case "done":
            finish({ ok: !!frame.ok, canceled: frame.canceled, error: frame.error });
            break;
        }
      };

      // SSE 以空行分帧；逐块解码并按 \n\n 切分
      for (;;) {
        const { value, done: streamDone } = await reader.read();
        if (streamDone) break;
        buffer += decoder.decode(value, { stream: true });
        let idx: number;
        while ((idx = buffer.indexOf("\n\n")) !== -1) {
          const frame = buffer.slice(0, idx).trim();
          buffer = buffer.slice(idx + 2);
          if (frame) handleFrame(frame);
        }
      }
      // 流结束但没有收到 done 帧（连接异常中断）
      if (!aborted) finish({ ok: false, error: "连接中断，更新状态未知" });
    } catch (err) {
      if (aborted || (err instanceof DOMException && err.name === "AbortError")) {
        finish({ ok: false, canceled: true });
      } else {
        finish({ ok: false, error: err instanceof Error ? err.message : "网络错误" });
      }
    }
  })();

  return {
    abort: () => {
      aborted = true;
      ctrl.abort();
    },
    done,
  };
}
