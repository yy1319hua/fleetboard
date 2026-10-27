import { cn } from "@/lib/cn";

export type Tone = "ok" | "warn" | "danger" | "info" | "idle" | "accent";

const dotColor: Record<Tone, string> = {
  ok: "bg-ok",
  warn: "bg-warn",
  danger: "bg-danger",
  info: "bg-info",
  idle: "bg-idle",
  accent: "bg-accent",
};

const textColor: Record<Tone, string> = {
  ok: "text-ok",
  warn: "text-warn",
  danger: "text-danger",
  info: "text-info",
  idle: "text-idle",
  accent: "text-accent",
};

/**
 * 状态徽标：圆点 + 文字。
 * DESIGN.md 强制「颜色不是唯一信号」——因此始终渲染文字标签。
 */
export function StatusBadge({
  tone,
  label,
  className,
  dotOnly = false,
}: {
  tone: Tone;
  label: string;
  className?: string;
  dotOnly?: boolean;
}) {
  if (dotOnly) {
    return (
      <span
        role="img"
        aria-label={label}
        title={label}
        className={cn("inline-block h-2 w-2 shrink-0 rounded-full", dotColor[tone], className)}
      />
    );
  }
  return (
    <span className={cn("inline-flex items-center gap-1.5 text-caption", textColor[tone], className)}>
      <span aria-hidden="true" className={cn("inline-block h-2 w-2 shrink-0 rounded-full", dotColor[tone])} />
      {label}
    </span>
  );
}

/** 中性计数/标签药丸（非状态语义，用 surface-2，不占语义色）。 */
export function Pill({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-badge border border-border bg-surface-2 px-1.5 py-0.5 text-caption text-text-muted",
        className,
      )}
    >
      {children}
    </span>
  );
}

/** 服务器连接状态 → 文案与色调。 */
export function serverTone(status: string): { tone: Tone; label: string } {
  switch (status) {
    case "online":
      return { tone: "ok", label: "在线" };
    case "offline":
      return { tone: "danger", label: "离线" };
    default:
      return { tone: "idle", label: "未知" };
  }
}

/** 容器状态 → 文案与色调（Docker State 取值）。 */
export function containerTone(state: string): { tone: Tone; label: string } {
  switch (state) {
    case "running":
      return { tone: "ok", label: "运行中" };
    case "exited":
      return { tone: "idle", label: "已停止" };
    case "paused":
      return { tone: "warn", label: "已暂停" };
    case "restarting":
      return { tone: "info", label: "重启中" };
    case "dead":
      return { tone: "danger", label: "异常" };
    default:
      return { tone: "idle", label: state || "未知" };
  }
}
