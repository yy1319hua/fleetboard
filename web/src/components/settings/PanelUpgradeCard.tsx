import { useQuery } from "@tanstack/react-query";
import { useEffect, useRef, useState } from "react";

import { Button } from "@/components/ui/Button";
import { Card, CardBody, CardHeader } from "@/components/ui/Card";
import { Dialog } from "@/components/ui/Dialog";
import { Field, Input } from "@/components/ui/Form";
import { toast } from "@/components/ui/Toast";
import {
  fetchHealth,
  fetchUpgradeInfo,
  fetchUpgradeStatus,
  triggerUpgrade,
  type UpgradeInfo,
  type UpgradeStatus,
} from "@/lib/system";

const STATE_LABEL: Record<string, string> = {
  idle: "空闲",
  preparing: "准备中",
  downloading: "下载中",
  verifying: "校验中",
  installing: "安装中",
  restarting: "重启服务",
  done: "已完成",
  failed: "失败",
};

/** 服务重启后最长等多久；超过即视为真故障，不再显示「升级中」。 */
const LOST_TIMEOUT_MS = 180_000;
const POLL_MS = 2_000;

/**
 * 面板更新（B2）：**全手动**。
 *
 * ① 默认只显示当前版本，不发任何请求；
 * ② 点「检查更新」才查 latest_version / can_upgrade；
 * ③ 不可升级时只显示只读横幅 + 后端中文 reason，不给可点按钮；
 * ④ 点「升级」还要输密码 + 目标版本二次确认；
 * ⑤ 升级会重启服务，本页必然短暂 502 —— 用 180s 窗口做失联判定。
 */
export function PanelUpgradeCard() {
  const health = useQuery({ queryKey: ["health"], queryFn: fetchHealth, staleTime: 60_000 });

  const [info, setInfo] = useState<UpgradeInfo | null>(null);
  const [checking, setChecking] = useState(false);
  const [checkErr, setCheckErr] = useState<string | null>(null);

  const [confirmOpen, setConfirmOpen] = useState(false);
  const [pwd, setPwd] = useState("");
  const [target, setTarget] = useState("");
  const [err, setErr] = useState<string | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const [status, setStatus] = useState<UpgradeStatus | null>(null);
  const [lost, setLost] = useState(false);
  const [waited, setWaited] = useState(0);
  const startedAt = useRef<number | null>(null);
  const timer = useRef<number | null>(null);

  const stopPolling = () => {
    if (timer.current !== null) {
      window.clearInterval(timer.current);
      timer.current = null;
    }
  };

  useEffect(() => () => stopPolling(), []);

  const poll = async () => {
    if (startedAt.current) setWaited(Math.floor((Date.now() - startedAt.current) / 1000));
    try {
      const s = await fetchUpgradeStatus();
      setStatus(s);
      setLost(false);
      if (s.state === "done" || s.state === "failed") {
        stopPolling();
        void health.refetch();
        if (s.state === "done") toast("升级完成，服务已重启", "ok");
        else toast(`升级失败：${s.error_code || "未知原因"}`, "danger");
      }
    } catch {
      // 服务正在重启时请求必然失败：窗口内一律按「升级中」处理，不弹错误。
      const elapsed = startedAt.current ? Date.now() - startedAt.current : 0;
      if (elapsed <= LOST_TIMEOUT_MS) {
        setLost(true);
      } else {
        stopPolling();
        toast("升级后服务长时间未恢复，请到服务器检查进程与日志", "danger");
      }
    }
  };

  const check = async () => {
    setChecking(true);
    setCheckErr(null);
    try {
      const next = await fetchUpgradeInfo();
      setInfo(next);
      setTarget(next.latest_version);
    } catch (e) {
      setCheckErr(e instanceof Error ? e.message : "检查失败");
    } finally {
      setChecking(false);
    }
  };

  const start = async () => {
    if (!pwd) {
      setErr("请输入当前账号密码");
      return;
    }
    setSubmitting(true);
    setErr(null);
    try {
      await triggerUpgrade(pwd, target.trim());
      startedAt.current = Date.now();
      setWaited(0);
      setLost(false);
      setConfirmOpen(false);
      setPwd("");
      setStatus({
        state: "preparing",
        phase_text: "已提交，等待服务端开始…",
        from: info?.current_version ?? health.data?.version ?? "",
        to: target.trim() || info?.latest_version || "",
        error_code: "",
        log_tail: [],
      });
      timer.current = window.setInterval(() => void poll(), POLL_MS);
      toast("升级已开始，服务会短暂重启", "ok");
    } catch (e) {
      const msg = e instanceof Error ? e.message : "提交失败";
      setErr(msg);
      toast(msg, "danger");
    } finally {
      setSubmitting(false);
    }
  };

  const running = status !== null && status.state !== "done" && status.state !== "failed";
  const currentVersion = health.data?.version ?? info?.current_version ?? "—";
  const phase = status ? STATE_LABEL[status.state] ?? status.state : "";

  return (
    <Card>
      <CardHeader title="面板更新" subtitle="手动检查、手动升级；不会自动升级" />
      <CardBody className="space-y-3">
        <div className="flex items-center justify-between gap-3 text-body-sm">
          <span className="text-text-muted">当前版本</span>
          <span className="font-mono text-mono text-text">{currentVersion}</span>
        </div>

        {running ? (
          <div className="space-y-2 rounded-control border border-border bg-surface-2 p-3">
            <div className="flex flex-wrap items-center justify-between gap-2 text-body-sm">
              <span className="text-text">
                正在升级：{phase}
                {status.from && status.to ? (
                  <span className="ml-1 font-mono text-mono-sm text-text-muted">
                    {status.from} → {status.to}
                  </span>
                ) : null}
              </span>
              <span className="font-mono text-mono-sm text-text-faint">已等待 {waited}s</span>
            </div>
            {lost ? (
              <p className="text-body-sm text-warn">
                服务正在重启，页面暂时连不上属正常现象；恢复后会自动继续，请不要关闭标签页。
              </p>
            ) : status.phase_text ? (
              <p className="text-body-sm text-text-muted">{status.phase_text}</p>
            ) : null}
            {status.log_tail.length > 0 ? (
              <pre className="max-h-40 overflow-auto rounded-control bg-terminal p-2 font-mono text-mono-sm text-text-muted">
                {status.log_tail.join("\n")}
              </pre>
            ) : null}
          </div>
        ) : status && (status.state === "done" || status.state === "failed") ? (
          <div
            className={
              status.state === "done"
                ? "rounded-control border border-border bg-surface-2 px-3 py-2 text-body-sm text-ok"
                : "rounded-control border border-border bg-surface-2 px-3 py-2 text-body-sm text-danger"
            }
          >
            {status.state === "done"
              ? `升级完成：${status.from} → ${status.to}`
              : `升级失败：${status.error_code || "未知原因"}`}
            <Button
              variant="ghost"
              size="sm"
              className="ml-2"
              onClick={() => {
                setStatus(null);
                setInfo(null);
                void health.refetch();
              }}
            >
              重新检查
            </Button>
          </div>
        ) : !info ? (
          <>
            <p className="text-caption text-text-faint">
              点「检查更新」才会联网查询最新版本；在此之前页面不会发起任何升级请求。
            </p>
            <div className="flex flex-wrap items-center gap-2">
              <Button variant="secondary" loading={checking} onClick={() => void check()}>
                检查更新
              </Button>
              {checkErr ? <span className="text-caption text-danger">{checkErr}</span> : null}
            </div>
          </>
        ) : (
          <>
            <div className="flex items-center justify-between gap-3 text-body-sm">
              <span className="text-text-muted">最新版本</span>
              <span className="font-mono text-mono text-text">{info.latest_version || "—"}</span>
            </div>
            {info.can_upgrade ? (
              <div className="flex flex-wrap items-center gap-2">
                <Button
                  variant="primary"
                  onClick={() => {
                    setErr(null);
                    setPwd("");
                    setConfirmOpen(true);
                  }}
                >
                  升级到 {info.latest_version || "最新版"}
                </Button>
                <Button variant="ghost" loading={checking} onClick={() => void check()}>
                  重新检查
                </Button>
              </div>
            ) : (
              <div className="rounded-control border border-border bg-surface-2 px-3 py-2 text-body-sm text-text-muted">
                {info.reason || (info.upgrade_enabled ? "当前环境不满足升级条件" : "面板未开启升级功能")}
              </div>
            )}
          </>
        )}
      </CardBody>

      <Dialog
        open={confirmOpen}
        title="确认升级面板"
        description="服务端会替换二进制与前端资源并重启，当前页面会短暂断开。"
        onClose={() => setConfirmOpen(false)}
        footer={
          <>
            <Button variant="ghost" onClick={() => setConfirmOpen(false)} disabled={submitting}>
              取消
            </Button>
            <Button variant="primary" loading={submitting} onClick={() => void start()}>
              确认升级
            </Button>
          </>
        }
      >
        <div className="space-y-3.5">
          <Field label="目标版本" htmlFor="upgrade-target" hint="留空则用后端判定出的最新版本">
            <Input
              id="upgrade-target"
              value={target}
              onChange={(e) => setTarget(e.target.value)}
              placeholder={info?.latest_version || "例如 v0.5.4"}
              className="font-mono"
            />
          </Field>
          <Field label="当前账号密码（确认身份）" htmlFor="upgrade-pwd" error={err}>
            <Input
              id="upgrade-pwd"
              type="password"
              autoComplete="current-password"
              value={pwd}
              onChange={(e) => setPwd(e.target.value)}
            />
          </Field>
          <p className="text-caption text-text-faint">
            升级过程中服务会重启，页面会短暂显示「正在重启」；若超过 3 分钟仍无法恢复，请到服务器检查进程。
          </p>
        </div>
      </Dialog>
    </Card>
  );
}
