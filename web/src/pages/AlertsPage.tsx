import { useMemo, useState } from "react";
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { Button } from "@/components/ui/Button";
import { Dialog } from "@/components/ui/Dialog";
import { EmptyState, ErrorState, SkeletonRows } from "@/components/ui/Feedback";
import { Field, Input, Select } from "@/components/ui/Form";
import { StatusBadge, type Tone } from "@/components/ui/StatusBadge";
import { toast } from "@/components/ui/Toast";
import {
  CHANNEL_LABEL,
  METRIC_LABEL,
  SEVERITY_LABEL,
  createAlertRule,
  deleteAlertRule,
  listAlertRules,
  listAlerts,
  markAlertRead,
  parseChannels,
  type CreateRuleInput,
} from "@/lib/alerts";
import { formatDateTime } from "@/lib/format";
import { useServers } from "@/lib/queries";
import { cn } from "@/lib/cn";
import type { AlertRule } from "@/lib/types";

type Tab = "events" | "rules";

function severityTone(s: string): Tone {
  if (s === "critical") return "danger";
  if (s === "warn") return "warn";
  return "info";
}

const ruleInitial = {
  server_id: "",
  metric: "cpu_pct" as CreateRuleInput["metric"],
  operator: ">" as CreateRuleInput["operator"],
  threshold: "80",
  severity: "warn" as CreateRuleInput["severity"],
  enabled: true,
  inapp: true,
  pushplus: true,
};

export function AlertsPage() {
  const qc = useQueryClient();
  const [tab, setTab] = useState<Tab>("events");
  const [unreadOnly, setUnreadOnly] = useState(false);
  const [ruleOpen, setRuleOpen] = useState(false);
  const [form, setForm] = useState(ruleInitial);

  const alerts = useQuery({
    queryKey: ["alerts", unreadOnly],
    queryFn: () => listAlerts({ unreadOnly, limit: 200 }),
    refetchInterval: 30_000,
  });

  const rules = useQuery({
    queryKey: ["alert-rules"],
    queryFn: listAlertRules,
    enabled: tab === "rules",
  });

  const servers = useServers();

  const read = useMutation({
    mutationFn: (id: number) => markAlertRead(id),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: ["alerts"] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "操作失败", "danger"),
  });

  const delRule = useMutation({
    mutationFn: (id: number) => deleteAlertRule(id),
    onSuccess: () => {
      toast("规则已删除", "ok");
      void qc.invalidateQueries({ queryKey: ["alert-rules"] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "删除失败", "danger"),
  });

  const addRule = useMutation({
    mutationFn: (input: CreateRuleInput) => createAlertRule(input),
    onSuccess: () => {
      toast("规则已创建", "ok");
      setRuleOpen(false);
      setForm(ruleInitial);
      void qc.invalidateQueries({ queryKey: ["alert-rules"] });
    },
    onError: (e) => toast(e instanceof Error ? e.message : "创建失败", "danger"),
  });

  const serverName = useMemo(() => {
    const map = new Map<number, string>();
    (servers.data ?? []).forEach((s) => map.set(s.id, s.name));
    return map;
  }, [servers.data]);

  const unreadCount = (alerts.data ?? []).filter((a) => !a.is_read).length;

  const submitRule = () => {
    const threshold = Number(form.threshold);
    if (form.metric !== "offline" && !Number.isFinite(threshold)) {
      toast("阈值需为数字", "danger");
      return;
    }
    const channels = [form.inapp ? "inapp" : "", form.pushplus ? "pushplus" : ""].filter(Boolean).join(",");
    if (!channels) {
      toast("至少选择一个通知通道", "danger");
      return;
    }
    addRule.mutate({
      server_id: form.server_id ? Number(form.server_id) : null,
      metric: form.metric,
      operator: form.operator,
      threshold: form.metric === "offline" ? 0 : threshold,
      severity: form.severity,
      enabled: form.enabled,
      notify_channels: channels,
    });
  };

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap items-end justify-between gap-3">
        <div>
          <h1 className="text-h1 text-text">通知中心</h1>
          <p className="mt-1 text-body-sm text-text-muted">
            未读 {unreadCount} 条 · 告警规则 {rules.data ? rules.data.length : "—"} 条
          </p>
        </div>
        <div className="flex items-center gap-2">
          <Button
            variant="secondary"
            onClick={() => void alerts.refetch()}
            disabled={alerts.isFetching}
          >
            刷新
          </Button>
          <Button
            variant="primary"
            onClick={() => {
              setTab("rules");
              setRuleOpen(true);
            }}
          >
            新建规则
          </Button>
        </div>
      </div>

      <div className="flex flex-wrap items-center justify-between gap-2">
        <div className="flex gap-1 rounded-control border border-border bg-surface-1 p-0.5">
          {([["events", "告警记录"], ["rules", "规则管理"]] as [Tab, string][]).map(([key, label]) => (
            <button
              key={key}
              type="button"
              onClick={() => setTab(key)}
              className={cn(
                "min-h-11 rounded-[5px] px-3 text-body-sm transition-colors duration-ui ease-ui sm:min-h-0 sm:h-8",
                tab === key ? "bg-accent-soft text-text" : "text-text-muted hover:text-text",
              )}
            >
              {label}
            </button>
          ))}
        </div>

        {tab === "events" ? (
          <label className="flex cursor-pointer items-center gap-2 text-body-sm text-text-muted">
            <input
              type="checkbox"
              checked={unreadOnly}
              onChange={(e) => setUnreadOnly(e.target.checked)}
              className="h-4 w-4 accent-[var(--accent)]"
            />
            只看未读
          </label>
        ) : null}
      </div>

      <div className="rounded-card border border-border bg-surface-1">
        {tab === "events" ? (
          alerts.isLoading ? (
            <SkeletonRows rows={6} cols={4} />
          ) : alerts.isError ? (
            <ErrorState
              message={alerts.error instanceof Error ? alerts.error.message : "加载失败"}
              onRetry={() => void alerts.refetch()}
            />
          ) : (alerts.data ?? []).length === 0 ? (
            <EmptyState
              title={unreadOnly ? "没有未读告警" : "暂无告警"}
              description="当指标超过规则阈值或服务器离线时，这里会出现告警；同时在应用内提示并按配置推送 PushPlus。"
            />
          ) : (
            <ul className="divide-y divide-border">
              {(alerts.data ?? []).map((a) => (
                <li key={a.id} className={cn("px-4 py-3", !a.is_read ? "bg-accent-soft/40" : "")}>
                  <div className="flex flex-wrap items-start justify-between gap-2">
                    <div className="min-w-0">
                      <div className="flex flex-wrap items-center gap-2">
                        <StatusBadge tone={severityTone(a.severity)} label={SEVERITY_LABEL[a.severity] ?? a.severity} />
                        <span className="text-body text-text">{a.title}</span>
                        {a.server_id ? (
                          <span className="text-caption text-text-faint">
                            {serverName.get(a.server_id) ?? `#${a.server_id}`}
                          </span>
                        ) : null}
                      </div>
                      <p className="mt-1 break-all text-body-sm text-text-muted">{a.message}</p>
                      <p className="mt-1 text-caption text-text-faint">{formatDateTime(a.created_at)}</p>
                    </div>
                    {!a.is_read ? (
                      <Button size="sm" variant="ghost" onClick={() => read.mutate(a.id)} loading={read.isPending}>
                        标记已读
                      </Button>
                    ) : (
                      <span className="text-caption text-text-faint">已读</span>
                    )}
                  </div>
                </li>
              ))}
            </ul>
          )
        ) : rules.isLoading ? (
          <SkeletonRows rows={5} cols={5} />
        ) : rules.isError ? (
          <ErrorState
            message={rules.error instanceof Error ? rules.error.message : "加载失败"}
            onRetry={() => void rules.refetch()}
          />
        ) : (rules.data ?? []).length === 0 ? (
          <EmptyState
            title="还没有告警规则"
            description="新建一条规则，例如「CPU > 80% 持续超限」或「服务器离线」，命中后会写入通知中心并按通道推送。"
            action={
              <Button variant="primary" onClick={() => setRuleOpen(true)}>
                新建规则
              </Button>
            }
          />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[820px] border-collapse">
              <thead className="bg-surface-2">
                <tr className="border-b border-border">
                  <th className="px-3 py-2 text-left"><span className="eyebrow">对象</span></th>
                  <th className="w-36 px-3 py-2 text-left"><span className="eyebrow">条件</span></th>
                  <th className="w-24 px-3 py-2 text-left"><span className="eyebrow">级别</span></th>
                  <th className="w-40 px-3 py-2 text-left"><span className="eyebrow">通道</span></th>
                  <th className="w-24 px-3 py-2 text-left"><span className="eyebrow">状态</span></th>
                  <th className="w-24 px-3 py-2 text-right"><span className="eyebrow">操作</span></th>
                </tr>
              </thead>
              <tbody>
                {(rules.data ?? []).map((r: AlertRule) => (
                  <tr key={r.id} className="h-10 border-b border-border last:border-0 hover:bg-surface-3">
                    <td className="px-3">
                      <span className="text-body text-text">{r.server_id ? serverName.get(r.server_id) ?? `#${r.server_id}` : "全部服务器"}</span>
                      <span className="ml-2 text-caption text-text-faint">{METRIC_LABEL[r.metric] ?? r.metric}</span>
                    </td>
                    <td className="tabular whitespace-nowrap px-3 font-mono text-mono-sm text-text-muted">
                      {r.metric === "offline" ? "不可达" : `${r.operator} ${r.threshold}`}
                    </td>
                    <td className="px-3">
                      <StatusBadge tone={severityTone(r.severity)} label={SEVERITY_LABEL[r.severity] ?? r.severity} />
                    </td>
                    <td className="px-3 text-body-sm text-text-muted">
                      {parseChannels(r.notify_channels)
                        .map((c) => CHANNEL_LABEL[c] ?? c)
                        .join(" · ") || "—"}
                    </td>
                    <td className="px-3">
                      <StatusBadge tone={r.enabled ? "ok" : "idle"} label={r.enabled ? "启用" : "停用"} />
                    </td>
                    <td className="px-3 text-right">
                      <Button
                        size="sm"
                        variant="ghost"
                        className="text-danger hover:text-danger"
                        onClick={() => {
                          if (!window.confirm("删除该规则？")) return;
                          delRule.mutate(r.id);
                        }}
                      >
                        删除
                      </Button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      <Dialog
        open={ruleOpen}
        title="新建告警规则"
        description="命中阈值后写入通知中心，并按所选通道推送。"
        onClose={() => setRuleOpen(false)}
        footer={
          <>
            <Button variant="ghost" onClick={() => setRuleOpen(false)} disabled={addRule.isPending}>
              取消
            </Button>
            <Button variant="primary" onClick={submitRule} loading={addRule.isPending}>
              创建
            </Button>
          </>
        }
      >
        <div className="space-y-3.5">
          <Field label="作用对象" htmlFor="rule-server" hint="留空表示对所有服务器生效">
            <Select id="rule-server" value={form.server_id} onChange={(e) => setForm({ ...form, server_id: e.target.value })}>
              <option value="">全部服务器</option>
              {(servers.data ?? []).map((s) => (
                <option key={s.id} value={String(s.id)}>
                  {s.name}
                </option>
              ))}
            </Select>
          </Field>

          <div className="grid grid-cols-1 gap-3.5 sm:grid-cols-2">
            <Field label="指标" htmlFor="rule-metric">
              <Select
                id="rule-metric"
                value={form.metric}
                onChange={(e) => setForm({ ...form, metric: e.target.value as CreateRuleInput["metric"] })}
              >
                <option value="cpu_pct">CPU 使用率</option>
                <option value="mem_pct">内存使用率</option>
                <option value="disk_pct">磁盘使用率</option>
                <option value="offline">离线（SSH 不可达）</option>
              </Select>
            </Field>

            <Field label="级别" htmlFor="rule-sev">
              <Select
                id="rule-sev"
                value={form.severity}
                onChange={(e) => setForm({ ...form, severity: e.target.value as CreateRuleInput["severity"] })}
              >
                <option value="info">提示</option>
                <option value="warn">警告</option>
                <option value="critical">严重</option>
              </Select>
            </Field>
          </div>

          {form.metric !== "offline" ? (
            <div className="grid grid-cols-2 gap-3.5">
              <Field label="比较" htmlFor="rule-op">
                <Select
                  id="rule-op"
                  value={form.operator}
                  onChange={(e) => setForm({ ...form, operator: e.target.value as CreateRuleInput["operator"] })}
                >
                  <option value=">">大于 &gt;</option>
                  <option value="<">小于 &lt;</option>
                </Select>
              </Field>
              <Field label="阈值（%）" htmlFor="rule-threshold">
                <Input
                  id="rule-threshold"
                  value={form.threshold}
                  onChange={(e) => setForm({ ...form, threshold: e.target.value })}
                  inputMode="decimal"
                />
              </Field>
            </div>
          ) : null}

          <Field label="通知通道">
            <div className="flex flex-wrap items-center gap-4 pt-1">
              <label className="flex cursor-pointer items-center gap-2 text-body-sm text-text-muted">
                <input
                  type="checkbox"
                  checked={form.inapp}
                  onChange={(e) => setForm({ ...form, inapp: e.target.checked })}
                  className="h-4 w-4 accent-[var(--accent)]"
                />
                应用内
              </label>
              <label className="flex cursor-pointer items-center gap-2 text-body-sm text-text-muted">
                <input
                  type="checkbox"
                  checked={form.pushplus}
                  onChange={(e) => setForm({ ...form, pushplus: e.target.checked })}
                  className="h-4 w-4 accent-[var(--accent)]"
                />
                PushPlus
              </label>
            </div>
          </Field>
        </div>
      </Dialog>
    </div>
  );
}
