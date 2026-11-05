import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "@/lib/cn";

/**
 * 面板：surface-1 + 1px 边框 + 8px 圆角 + 顶部 1px 亮线（border-hi）。
 * 无投影、不嵌套（DESIGN.md 第 4/6 节）。
 *
 * 顶边亮线是实色 1px，不是渐变也不是发光边框，用于在深色下把卡片从背景里
 * "托"出来一档——原四周边框 1.32:1 太弱，卡片与背景几乎同色（1.08:1）。
 */
export function Card({ className, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return (
    <div
      {...rest}
      className={cn(
        "relative rounded-card border border-border bg-surface-1",
        "before:pointer-events-none before:absolute before:inset-x-px before:top-0 before:h-px before:rounded-t-card before:bg-border-hi",
        className,
      )}
    />
  );
}

export function CardHeader({
  title,
  subtitle,
  actions,
  className,
}: {
  title: ReactNode;
  subtitle?: ReactNode;
  actions?: ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "flex flex-wrap items-center justify-between gap-3 border-b border-border px-4 py-3 sm:px-5",
        className,
      )}
    >
      <div className="min-w-0">
        <div className="text-h3 text-text">{title}</div>
        {subtitle ? <div className="mt-0.5 text-body-sm text-text-muted">{subtitle}</div> : null}
      </div>
      {actions ? <div className="flex items-center gap-2">{actions}</div> : null}
    </div>
  );
}

export function CardBody({ className, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return <div {...rest} className={cn("px-4 py-4 sm:px-5", className)} />;
}
