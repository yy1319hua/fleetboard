import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { Button } from "@/components/ui/Button";
import { InlineLoading } from "@/components/ui/Feedback";
import { createLogsTicket, logsSocketURL } from "@/lib/docker";
import { cn } from "@/lib/cn";

const ROW_H = 20; // 与 text-mono-sm 行高一致
const MAX_LINES = 5000; // 内存上限，超出丢弃最早的
const OVERSCAN = 12; // 上下多渲染几行，滚动更顺

type Status = "connecting" | "live" | "closed" | "error";

function lineTone(line: string): string {
  if (/\b(ERROR|ERR|FATAL|panic)\b/i.test(line)) return "text-danger";
  if (/\b(WARN|WARNING)\b/i.test(line)) return "text-warn";
  if (/\b(INFO|NOTICE)\b/i.test(line)) return "text-info";
  return "text-text";
}

/**
 * 实时日志终端（WebSocket + 固定行高虚拟滚动，万行不卡）。
 * 鉴权：先取 60s 一次性票据，再用 ?ticket= 建连（浏览器 WS 无法带 Authorization 头）。
 */
export function LogTerminal({ serverID, cid, title }: { serverID: number; cid: string; title: string }) {
  const [lines, setLines] = useState<string[]>([]);
  const [status, setStatus] = useState<Status>("connecting");
  const [errMsg, setErrMsg] = useState<string | null>(null);
  const [autoScroll, setAutoScroll] = useState(true);
  const [scrollTop, setScrollTop] = useState(0);
  const [viewportH, setViewportH] = useState(360);
  const [reconnectKey, setReconnectKey] = useState(0);

  const boxRef = useRef<HTMLDivElement>(null);
  const partialRef = useRef("");
  const wsRef = useRef<WebSocket | null>(null);

  useEffect(() => {
    let cancelled = false;
    let ws: WebSocket | null = null;

    setLines([]);
    setStatus("connecting");
    setErrMsg(null);
    partialRef.current = "";

    (async () => {
      try {
        const { ticket } = await createLogsTicket(serverID, cid);
        if (cancelled) return;

        ws = new WebSocket(logsSocketURL(serverID, cid, ticket, 300));
        wsRef.current = ws;

        ws.onopen = () => {
          if (!cancelled) setStatus("live");
        };
        ws.onmessage = (ev) => {
          if (cancelled) return;
          const text = typeof ev.data === "string" ? ev.data : "";
          const merged = partialRef.current + text;
          const parts = merged.split("\n");
          partialRef.current = parts.pop() ?? "";
          const incoming = parts.filter((l) => l.length > 0);
          if (incoming.length === 0) return;
          setLines((prev) => {
            const next = prev.concat(incoming);
            return next.length > MAX_LINES ? next.slice(next.length - MAX_LINES) : next;
          });
        };
        ws.onerror = () => {
          if (!cancelled) {
            setStatus("error");
            setErrMsg("连接中断，可能是票据过期或服务器不可达");
          }
        };
        ws.onclose = () => {
          if (!cancelled) setStatus((s) => (s === "error" ? s : "closed"));
        };
      } catch (e) {
        if (cancelled) return;
        setStatus("error");
        setErrMsg(e instanceof Error ? e.message : "无法建立日志连接");
      }
    })();

    return () => {
      cancelled = true;
      ws?.close();
      wsRef.current = null;
    };
  }, [serverID, cid, reconnectKey]);

  // 视口高度
  useEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const ro = new ResizeObserver(() => setViewportH(el.clientHeight));
    ro.observe(el);
    setViewportH(el.clientHeight);
    return () => ro.disconnect();
  }, []);

  // 自动滚到底
  const scrollToBottom = useCallback(() => {
    const el = boxRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
  }, []);

  useEffect(() => {
    if (autoScroll) scrollToBottom();
  }, [lines, autoScroll, scrollToBottom]);

  const onScroll = () => {
    const el = boxRef.current;
    if (!el) return;
    setScrollTop(el.scrollTop);
    const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - 24;
    setAutoScroll(atBottom);
  };

  const { start, end } = useMemo(() => {
    const first = Math.max(0, Math.floor(scrollTop / ROW_H) - OVERSCAN);
    const count = Math.ceil(viewportH / ROW_H) + OVERSCAN * 2;
    return { start: first, end: Math.min(lines.length, first + count) };
  }, [scrollTop, viewportH, lines.length]);

  const visible = lines.slice(start, end);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center justify-between gap-2 border-b border-border px-3 py-2">
        <div className="min-w-0">
          <div className="truncate font-mono text-mono-sm text-text">{title}</div>
          <div className="text-caption text-text-faint">
            {status === "connecting" ? "连接中…" : null}
            {status === "live" ? `实时 · ${lines.length} 行` : null}
            {status === "closed" ? `已断开 · ${lines.length} 行` : null}
            {status === "error" ? (errMsg ?? "连接失败") : null}
          </div>
        </div>
        <div className="flex shrink-0 items-center gap-1.5">
          <Button
            size="sm"
            variant="ghost"
            onClick={() => setAutoScroll((v) => !v)}
            title={autoScroll ? "暂停自动滚动" : "恢复自动滚动"}
          >
            {autoScroll ? "暂停滚动" : "跟随尾部"}
          </Button>
          <Button size="sm" variant="ghost" onClick={() => setLines([])}>
            清屏
          </Button>
          <Button size="sm" variant="secondary" onClick={() => setReconnectKey((k) => k + 1)}>
            重连
          </Button>
        </div>
      </div>

      {status === "connecting" && lines.length === 0 ? (
        <div className="px-3 py-3">
          <InlineLoading label="建立日志连接" />
        </div>
      ) : null}

      <div
        ref={boxRef}
        onScroll={onScroll}
        className="min-h-0 flex-1 overflow-auto bg-[var(--terminal)] px-3 py-2"
        aria-label="容器日志"
      >
        {lines.length === 0 ? (
          <p className="text-mono-sm text-text-faint">暂无日志输出。</p>
        ) : (
          <div style={{ height: lines.length * ROW_H, position: "relative" }}>
            <div style={{ transform: `translateY(${start * ROW_H}px)` }}>
              {visible.map((line, i) => (
                <div
                  key={start + i}
                  className={cn("whitespace-pre-wrap break-all font-mono text-mono-sm", lineTone(line))}
                  style={{ height: ROW_H, lineHeight: `${ROW_H}px` }}
                >
                  {line}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
