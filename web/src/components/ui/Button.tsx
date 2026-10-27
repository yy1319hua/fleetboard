import type { ButtonHTMLAttributes } from "react";

import { cn } from "@/lib/cn";

type Variant = "primary" | "secondary" | "ghost" | "danger";
type Size = "sm" | "md";

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: Variant;
  size?: Size;
  /** 加载态：禁用交互并显示占位文案 */
  loading?: boolean;
}

/** 变体样式对应 DESIGN.md 第 4 节「按钮」。移动端点击区由 min-h-11 保证 ≥44px。 */
const variants: Record<Variant, string> = {
  primary: "bg-accent text-text-inverse hover:bg-accent-hover border border-transparent",
  secondary: "bg-surface-2 text-text border border-border hover:bg-surface-3",
  ghost: "bg-transparent text-text-muted hover:text-text hover:bg-surface-2 border border-transparent",
  danger: "bg-danger text-white border border-transparent hover:opacity-90",
};

const sizes: Record<Size, string> = {
  sm: "h-8 px-2.5 text-body-sm",
  md: "h-[34px] px-3.5 text-body",
};

export function Button({
  variant = "secondary",
  size = "md",
  loading = false,
  disabled,
  className,
  children,
  ...rest
}: ButtonProps) {
  return (
    <button
      {...rest}
      disabled={disabled || loading}
      className={cn(
        "inline-flex items-center justify-center gap-1.5 whitespace-nowrap rounded-control font-medium",
        "transition-colors duration-ui ease-ui",
        "disabled:cursor-not-allowed disabled:opacity-40",
        "touch-manipulation min-h-11 sm:min-h-0",
        variants[variant],
        sizes[size],
        className,
      )}
    >
      {loading ? "处理中…" : children}
    </button>
  );
}
