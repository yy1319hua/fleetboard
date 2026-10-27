import { useEffect, useRef, useState } from "react";
import { useOutletContext } from "react-router-dom";

import { Button } from "@/components/ui/Button";
import { StatusBadge } from "@/components/ui/StatusBadge";
import { toast } from "@/components/ui/Toast";
import { streamPackageUpdate } from "@/lib/packages";
import { cn } from "@/lib/cn";
import type { Server } from "@/lib/types";

interface Ctx {
  server: Server;
}

type RunState = "idle" | "running" | "done";

/** 单次更新会话的本地状态：日志行 + 终态。 */
interface RunLog {
  state: RunState;
  lines: string[];
  result: { ok: boolean; canceled?: boolean; error?: string } | null;
}

const initialState: RunLog = { state: "idle", lines: [], result: null };

/**
 * M6.9 包更新面板：apt update && upgrade -y 的流式进度（SSE）。
 *
 * - 「开始更新」直接对目标机执行 root 全量升级（后端 M5.4 已固定命令），
 *   前端置顶显著警示，按钮二次确认文案明确。
 * - 进行中可「取消」：abort 请求 → 后端向远端 apt 发 SIGINT。
 * - 终端风格日志区自动滚底；失败仅展示统一文案（原始错误不回传）。
 */
export function ServerPackagesTab() {
  const { server } = useOutletContext<Ctx>();

  const [run, setRun] = useState<RunLog>(initialState);
  const streamRef = useRef<{ abort: () => void } | null>(null);
  const logEndRef = useRef<HTMLDivElement | null>(null);

  // 自动滚底：新行或终态变化时
  useEffect(() => {
    logEndRef.current?.scrollIntoView({ block: "end" });
  }, [run.lines.length, run.state]);

  // 卸载时中止进行中的请求
  useEffect(() => () => streamRef.current?.abort(), []);

  const start = () => {
    if (run.state === "running") return;
    setRun({ state: "running", lines: [], result: null });

    const stream = streamPackageUpdate(server.id, {
      onStarted: (message) =>
        setRun((prev) =>
          prev.state === "running" ? { ...prev, lines: [...prev.lines, `# ${message}`] } : prev,
        ),
      onLine: (line) =>
        setRun((prev) => {
          // 4000 行封顶防内存膨胀；apt 输出在此场景远达不到
          const lines = prev.lines.length >= 4000 ? prev.lines.slice(-3500) : prev.lines;
          return { ...prev, lines: [...lines, line] };
        }),
      onDone: (result) => {
        streamRef.current = null;
        setRun((prev) => ({ ...prev, state: "done", result }));
        if (result.ok) toast("软件包更新完成", "ok");
        else if (result.canceled) toast("已取消更新", "info");
        else toast(result.error ?? "更新失败", "danger");
      },
    });
    streamRef.current = stream;
  };

  const cancel = () => streamRef.current?.abort();

  const running = run.state === "running";

  return (
    <div className="space-y-4">
      {/* 操作区：移动优先单列，按钮大且易触达 */}
      <div className="rounded-card border border-border bg-surface-1 p-4">
        <div className="flex flex-col gap-3">
          <div className="flex items-center justify-between gap-3">
            <div>
              <p className="text-body font-medium text-text">软件包更新</p>
              <p className="text-caption text-text-muted">
                apt update && upgrade -y，对目标机执行全量升级
              </p>
            </div>
            {running ? <StatusBadge tone="warn" label="进行中" /> : null}
          </div>

          <div className="rounded-card border border-warn/30 bg-warn/10 p-3 text-caption text-text">
            ⚠️ 将以 root 直接升级该服务器全部软件包，可能触发服务重启。请确认非业务高峰后执行。
          </div>

          <div className="flex gap-3">
            {running ? (
              <Button variant="danger" className="min-h-11 flex-1" onClick={cancel}>
                取消更新
              </Button>
            ) : (
              <Button
                variant="primary"
                className="min-h-11 flex-1"
                onClick={start}
                disabled={server.connection_status === "offline"}
              >
                {run.state === "done" ? "再次更新" : "开始更新"}
              </Button>
            )}
          </div>
        </div>
      </div>

      {/* 日志区 */}
      <div>
        <div className="mb-1 flex items-center justify-between">
          <p className="text-caption text-text-muted">输出</p>
          {run.state === "done" && run.result ? (
            <p
              className={cn(
                "text-caption",
                run.result.ok
                  ? "text-ok"
                  : run.result.canceled
                    ? "text-text-muted"
                    : "text-danger",
              )}
            >
              {run.result.ok
                ? "✓ 更新完成"
                : run.result.canceled
                  ? "已取消"
                  : `✗ ${run.result.error ?? "更新失败"}`}
            </p>
          ) : null}
        </div>
        <div
          className="min-h-64 max-h-[60vh] overflow-y-auto rounded-card border border-border p-3"
          style={{ backgroundColor: "var(--terminal)" }}
          role="log"
          aria-live="polite"
        >
          {run.lines.length === 0 ? (
            <p className="font-mono text-caption text-text-faint">
              {run.state === "running" ? "连接中…" : "尚无输出。点「开始更新」后此处实时显示 apt 进度。"}
            </p>
          ) : (
            <pre className="whitespace-pre-wrap break-all font-mono text-caption leading-relaxed text-text">
              {run.lines.join("\n")}
            </pre>
          )}
          <div ref={logEndRef} />
        </div>
      </div>
    </div>
  );
}
