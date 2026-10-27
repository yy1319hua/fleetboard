import { useEffect, useRef, type ReactNode } from "react";

import { cn } from "@/lib/cn";

/**
 * 模态框：唯一允许使用投影的层级（DESIGN.md 第 6 节 level 3）。
 * 轻量自实现，不引 Radix：仅需 Esc 关闭、遮罩点击关闭、初始聚焦。
 */
export function Dialog({
  open,
  title,
  description,
  onClose,
  children,
  footer,
  width = "max-w-lg",
}: {
  open: boolean;
  title: string;
  description?: string;
  onClose: () => void;
  children: ReactNode;
  footer?: ReactNode;
  width?: string;
}) {
  const panelRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;

    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", onKey);
    // 打开时聚焦首个可交互元素
    const focusable = panelRef.current?.querySelector<HTMLElement>(
      "input, textarea, select, button, [tabindex]:not([tabindex='-1'])",
    );
    focusable?.focus();

    const prevOverflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = prevOverflow;
    };
  }, [open, onClose]);

  if (!open) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-end justify-center p-0 sm:items-center sm:p-4">
      <div
        className="absolute inset-0 bg-[#05070a]/70"
        onClick={onClose}
        aria-hidden="true"
      />
      <div
        ref={panelRef}
        role="dialog"
        aria-modal="true"
        aria-label={title}
        className={cn(
          "relative w-full rounded-t-panel border border-border bg-surface-1 shadow-modal sm:rounded-panel",
          width,
        )}
      >
        <div className="border-b border-border px-4 py-3 sm:px-5">
          <h2 className="text-h3 text-text">{title}</h2>
          {description ? <p className="mt-0.5 text-body-sm text-text-muted">{description}</p> : null}
        </div>

        <div className="max-h-[70vh] overflow-y-auto px-4 py-4 sm:px-5">{children}</div>

        {footer ? (
          <div className="flex items-center justify-end gap-2 border-t border-border px-4 py-3 sm:px-5">{footer}</div>
        ) : null}
      </div>
    </div>
  );
}
