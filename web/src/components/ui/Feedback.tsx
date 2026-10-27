import type { ReactNode } from "react";

import { cn } from "@/lib/cn";

/** 空状态：一句话说明 + 可选主操作。不放大插画（克制原则）。 */
export function EmptyState({
  title,
  description,
  action,
  className,
}: {
  title: string;
  description?: ReactNode;
  action?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cn("flex flex-col items-center justify-center gap-2 px-6 py-14 text-center", className)}>
      <div className="text-h3 text-text">{title}</div>
      {description ? <div className="max-w-md text-body-sm text-text-muted">{description}</div> : null}
      {action ? <div className="mt-2">{action}</div> : null}
    </div>
  );
}

/** 骨架屏：加载时保持版式不跳动。 */
export function Skeleton({ className }: { className?: string }) {
  return <div className={cn("animate-pulse rounded-control bg-surface-2", className)} aria-hidden="true" />;
}

/** 骨架表格：用于列表首次加载。 */
export function SkeletonRows({ rows = 5, cols = 4 }: { rows?: number; cols?: number }) {
  return (
    <div className="divide-y divide-border">
      {Array.from({ length: rows }).map((_, r) => (
        <div key={r} className="flex items-center gap-3 px-4 py-2.5">
          {Array.from({ length: cols }).map((__, c) => (
            <Skeleton key={c} className={cn("h-4", c === 0 ? "w-1/3" : "w-1/6")} />
          ))}
        </div>
      ))}
    </div>
  );
}

/** 阻塞式错误提示（含重试）。 */
export function ErrorState({
  message,
  onRetry,
}: {
  message: string;
  onRetry?: () => void;
}) {
  return (
    <div className="flex flex-col items-center gap-3 px-6 py-12 text-center">
      <div className="text-h3 text-danger">加载失败</div>
      <div className="max-w-md text-body-sm text-text-muted">{message}</div>
      {onRetry ? (
        <button
          type="button"
          onClick={onRetry}
          className="min-h-11 rounded-control border border-border bg-surface-2 px-3.5 text-body text-text hover:bg-surface-3 sm:min-h-0 sm:h-[34px]"
        >
          重试
        </button>
      ) : null}
    </div>
  );
}

/** 行内加载指示：三个点，无无限旋转装饰（DESIGN.md 禁用旋转装饰）。 */
export function InlineLoading({ label = "加载中" }: { label?: string }) {
  return (
    <span className="inline-flex items-center gap-1.5 text-caption text-text-muted">
      <span className="flex gap-0.5" aria-hidden="true">
        <span className="h-1 w-1 animate-pulse rounded-full bg-text-faint" />
        <span className="h-1 w-1 animate-pulse rounded-full bg-text-faint [animation-delay:120ms]" />
        <span className="h-1 w-1 animate-pulse rounded-full bg-text-faint [animation-delay:240ms]" />
      </span>
      {label}
    </span>
  );
}
