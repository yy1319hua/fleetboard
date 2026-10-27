import { apiDelete, apiGet, apiPost, withQuery } from "@/lib/api";
import type { AlertEvent, AlertRule } from "@/lib/types";

export function listAlerts(opts: { unreadOnly?: boolean; limit?: number } = {}) {
  return apiGet<AlertEvent[]>(
    withQuery("/api/alerts", {
      unread: opts.unreadOnly ? 1 : undefined,
      limit: opts.limit ?? 100,
    }),
  );
}

export function markAlertRead(id: number) {
  return apiPost<{ id: number; is_read: boolean }>(`/api/alerts/${id}/read`);
}

export function listAlertRules() {
  return apiGet<AlertRule[]>("/api/alert-rules");
}

export interface CreateRuleInput {
  server_id?: number | null;
  metric: "cpu_pct" | "mem_pct" | "disk_pct" | "offline";
  operator: ">" | "<";
  threshold: number;
  severity: "info" | "warn" | "critical";
  enabled: boolean;
  notify_channels: string;
}

export function createAlertRule(input: CreateRuleInput) {
  return apiPost<AlertRule>("/api/alert-rules", input);
}

export function deleteAlertRule(id: number) {
  return apiDelete<{ deleted: number }>(`/api/alert-rules/${id}`);
}

/** 指标 → 中文名。 */
export const METRIC_LABEL: Record<string, string> = {
  cpu_pct: "CPU 使用率",
  mem_pct: "内存使用率",
  disk_pct: "磁盘使用率",
  offline: "离线",
};

export const SEVERITY_LABEL: Record<string, string> = {
  info: "提示",
  warn: "警告",
  critical: "严重",
};

/** notify_channels 是逗号分隔字符串。 */
export function parseChannels(s: string): string[] {
  return s
    .split(",")
    .map((x) => x.trim())
    .filter(Boolean);
}

export const CHANNEL_LABEL: Record<string, string> = {
  inapp: "应用内",
  pushplus: "PushPlus",
};
