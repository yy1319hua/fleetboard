/**
 * 极简类名合并：过滤假值后以空格连接。
 * 不引 clsx/tailwind-merge，避免为此增加依赖（组件样式冲突由调用方保证）。
 */
export type ClassValue = string | false | null | undefined;

export function cn(...values: ClassValue[]): string {
  return values.filter(Boolean).join(" ");
}
