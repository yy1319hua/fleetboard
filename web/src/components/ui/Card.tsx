import type { HTMLAttributes, ReactNode } from "react";

import { cn } from "@/lib/cn";

/** 面板：surface-1 + 1px 边框 + 8px 圆角，无投影、不嵌套（DESIGN.md 第 4/6 节）。 */
export function Card({ className, ...rest }: HTMLAttributes<HTMLDivElement>) {
  return <div {...rest} className={cn("rounded-card border border-border bg-surface-1", className)} />;
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
