import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Field, Input, Textarea } from "@/components/ui/Form";
import { toast } from "@/components/ui/Toast";
import { fetchSettings, saveSettings, testPushChannel } from "@/lib/settings";
import type { SecretView } from "@/lib/settings";

/** 判断 settings 项是否为敏感掩码视图。 */
function isSecret(v: string | SecretView): v is SecretView {
  return typeof v === "object" && v !== null && "masked" in v;
}

/** 文本项取值；敏感项取掩码占位（回写时后端自动跳过）。 */
function itemText(v: string | SecretView | undefined): string {
  if (v === undefined) return "";
  return isSecret(v) ? v.masked : v;
}

function CardRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="flex items-center justify-between gap-3 py-1.5 text-body-sm">
      <span className="text-text-muted">{label}</span>
      <span className="font-mono text-mono text-text">{value}</span>
    </div>
  );
}

/**
 * 设置页（M8.1c）：告警推送 / 采集与保留 / Compose 白名单 / 只读信息。
 * 保存 = PUT /api/settings 批量提交，热生效（无需重启）。
 * 账号修改与 M8.1e（JWT ver epoch）同批，当前不在此页。
 */
export function SettingsPage() {
  const qc = useQueryClient();
  const { data, isLoading } = useQuery({
    queryKey: ["settings"],
    queryFn: fetchSettings,
  });

  // 表单状态：GET 到的值（敏感项为掩码）作为初始值，掩码原样回传后端会跳过
  const [pushplus, setPushplus] = useState("");
  const [interval, setInterval_] = useState("30");
  const [retention, setRetention] = useState("30");
  const [offline, setOffline] = useState("2");
  const [composeRoots, setComposeRoots] = useState("");

  useEffect(() => {
    if (!data) return;
    const it = data.items;
    setPushplus(itemText(it["pushplus.token"]));
    setInterval_(itemText(it["monitor.interval"]));
    setRetention(itemText(it["metrics.retention_days"]));
    setOffline(itemText(it["monitor.offline_threshold"]));
    setComposeRoots(itemText(it["compose.roots"]));
  }, [data]);

  const save = useMutation({
    mutationFn: () =>
      saveSettings({
        "pushplus.token": pushplus,
        "monitor.interval": interval,
        "metrics.retention_days": retention,
        "monitor.offline_threshold": offline,
        "compose.roots": composeRoots,
      }),
    onSuccess: (res) => {
      qc.setQueryData(["settings"], res);
      toast("已保存，配置热生效", "ok");
    },
    onError: (e: Error) => toast(e.message, "danger"),
  });

  const testPush = useMutation({
    // 传输入框当前值：允许先测未保存的新 token
    mutationFn: () => testPushChannel(pushplus.startsWith("****") ? undefined : pushplus),
    onSuccess: () => toast("测试消息已发送，请查看微信", "ok"),
    onError: (e: Error) => toast(e.message, "danger"),
  });

  return (
    <div className="space-y-4">
      <h1 className="text-h1 text-text">设置</h1>

      {/* 告警推送 */}
      <Card>
        <CardHeader title="告警推送" subtitle="PushPlus 微信推送，改后保存即热生效" />
        <CardBody className="space-y-3">
          <Field label="PushPlus Token" hint="点「测试」会向你的微信发一条测试消息；只显示尾 4 位">
            <div className="flex gap-2">
              <Input
                value={pushplus}
                onChange={(e) => setPushplus(e.target.value)}
                placeholder="尚未配置"
                autoComplete="off"
                className="flex-1"
              />
              <Button variant="secondary" loading={testPush.isPending} onClick={() => testPush.mutate()}>
                测试
              </Button>
            </div>
          </Field>
        </CardBody>
      </Card>

      {/* 采集与保留 */}
      <Card>
        <CardHeader title="采集与保留" subtitle="保存后热生效，无需重启服务" />
        <CardBody className="grid grid-cols-1 gap-3 sm:grid-cols-2">
          <Field label="采集间隔（秒）">
            <Input
              type="number"
              min={5}
              value={interval}
              onChange={(e) => setInterval_(e.target.value)}
              inputMode="numeric"
            />
          </Field>
          <Field label="离线阈值（连续失败次数）">
            <Input
              type="number"
              min={1}
              value={offline}
              onChange={(e) => setOffline(e.target.value)}
              inputMode="numeric"
            />
          </Field>
          <Field label="指标保留天数">
            <Input
              type="number"
              min={1}
              value={retention}
              onChange={(e) => setRetention(e.target.value)}
              inputMode="numeric"
            />
          </Field>
        </CardBody>
      </Card>

      {/* Compose 白名单 */}
      <Card>
        <CardHeader title="Compose 可读写根目录" subtitle="逗号分隔；保存后即时生效" />
        <CardBody>
          <Field label="根目录列表">
            <Textarea
              rows={2}
              value={composeRoots}
              onChange={(e) => setComposeRoots(e.target.value)}
              placeholder="/opt/compose, /srv/stacks"
            />
          </Field>
        </CardBody>
      </Card>

      {/* 只读信息 */}
      <Card>
        <CardHeader title="只读信息" />
        <CardBody>
          <CardRow label="加密主密钥 KEY" value={`${data?.readonly?.key_masked ?? "****"}（不可查看与修改）`} />
          <CardRow label="JWT 密钥" value="已入库，仅尾 4 位可见" />
          <CardRow label="监听端口" value={`${data?.readonly?.port ?? "—"}（修改需编辑 .env 后重启）`} />
        </CardBody>
      </Card>

      {/* 账号与安全（第二批，随 M8.1e） */}
      <Card className="opacity-60">
        <CardHeader title="账号与安全" subtitle="修改密码（其他端登录态失效）将随后续 JWT 安全批次提供" />
      </Card>

      <Button
        variant="primary"
        className="w-full"
        loading={save.isPending}
        disabled={isLoading}
        onClick={() => save.mutate()}
      >
        保存设置
      </Button>
      <p className="text-center text-caption text-text-faint">保存即热生效，无需重启</p>
    </div>
  );
}
