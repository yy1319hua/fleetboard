import { useEffect, useState } from "react";

import { cn } from "@/lib/cn";

type Tone = "ok" | "danger" | "info";

interface ToastItem {
  id: number;
  message: string;
  tone: Tone;
}

type Listener = (item: ToastItem) => void;

const listeners = new Set<Listener>();
let seq = 0;

/** 触发一条轻提示（非阻塞）。 */
export function toast(message: string, tone: Tone = "info"): void {
  const item: ToastItem = { id: (seq += 1), message, tone };
  listeners.forEach((fn) => fn(item));
}

const toneStyle: Record<Tone, string> = {
  ok: "border-ok/40 text-ok",
  danger: "border-danger/40 text-danger",
  info: "border-border-strong text-text",
};

/** 提示容器：挂在应用根部，最多同时显示 3 条，4 秒自动消失。 */
export function ToastHost() {
  const [items, setItems] = useState<ToastItem[]>([]);

  useEffect(() => {
    const onPush: Listener = (item) => {
      setItems((prev) => [...prev.slice(-2), item]);
      window.setTimeout(() => {
        setItems((prev) => prev.filter((i) => i.id !== item.id));
      }, 4000);
    };
    listeners.add(onPush);
    return () => {
      listeners.delete(onPush);
    };
  }, []);

  if (items.length === 0) return null;

  return (
    <div
      className="pointer-events-none fixed inset-x-0 top-3 z-[60] flex flex-col items-center gap-2 px-3"
      role="status"
      aria-live="polite"
    >
      {items.map((item) => (
        <div
          key={item.id}
          className={cn(
            "pointer-events-auto max-w-md rounded-control border bg-surface-2 px-3 py-2 text-body-sm shadow-modal",
            toneStyle[item.tone],
          )}
        >
          {item.message}
        </div>
      ))}
    </div>
  );
}
