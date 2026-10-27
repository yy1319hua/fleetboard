import { useEffect, useState } from "react";

import { Button } from "@/components/ui/Button";
import { toast } from "@/components/ui/Toast";

/**
 * PWA 安装提示（M6.10）。
 *
 * - Chromium 系：捕获 beforeinstallprompt，弹出横幅调用原生安装流程。
 * - iOS Safari：无该事件，识别后提示「分享 → 添加到主屏幕」。
 * - 已在独立模式（安装后）运行时不显示；本会话点「暂不」后不再打扰。
 */

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: "accepted" | "dismissed" }>;
}

const DISMISS_KEY = "fleetboard.pwa-install-dismissed";

type Mode = "idle" | "native" | "ios";

function detectMode(): Mode {
  if (
    window.matchMedia("(display-mode: standalone)").matches ||
    (window.navigator as Navigator & { standalone?: boolean }).standalone === true
  ) {
    return "idle";
  }
  const ua = navigator.userAgent;
  if (/iphone|ipad|ipod/i.test(ua)) return "ios";
  return "idle";
}

export function InstallPrompt() {
  const [evt, setEvt] = useState<BeforeInstallPromptEvent | null>(null);
  const [mode, setMode] = useState<Mode>("idle");
  const [dismissed, setDismissed] = useState(() => sessionStorage.getItem(DISMISS_KEY) === "1");

  useEffect(() => {
    setMode(detectMode());

    const onPrompt = (e: Event) => {
      e.preventDefault();
      setEvt(e as BeforeInstallPromptEvent);
      setMode((m) => (m === "ios" ? m : "native"));
    };
    const onInstalled = () => {
      setEvt(null);
      setMode("idle");
      toast("安装完成", "ok");
    };

    window.addEventListener("beforeinstallprompt", onPrompt);
    window.addEventListener("appinstalled", onInstalled);
    return () => {
      window.removeEventListener("beforeinstallprompt", onPrompt);
      window.removeEventListener("appinstalled", onInstalled);
    };
  }, []);

  if (mode === "idle" || dismissed) return null;

  const dismiss = () => {
    sessionStorage.setItem(DISMISS_KEY, "1");
    setDismissed(true);
  };

  const install = async () => {
    if (mode === "ios" || !evt) return;
    await evt.prompt();
    const { outcome } = await evt.userChoice;
    if (outcome === "dismissed") dismiss();
    else setEvt(null);
  };

  return (
    <div
      role="region"
      aria-label="安装提示"
      className="fixed inset-x-3 bottom-[calc(64px+env(safe-area-inset-bottom))] z-30 rounded-card border border-border bg-surface-1 p-3 shadow-lg lg:inset-x-auto lg:bottom-4 lg:left-4 lg:w-80"
    >
      <p className="text-body-sm text-text">安装 fleetboard 到主屏幕</p>
      <p className="mt-0.5 text-caption text-text-muted">
        {mode === "ios" ? "点 Safari 底部「分享」→「添加到主屏幕」即可离线打开。" : "独立窗口运行，像本机应用一样使用。"}
      </p>
      <div className="mt-2.5 flex gap-2">
        {mode === "native" ? (
          <Button variant="primary" size="sm" className="min-h-11 flex-1 sm:min-h-0" onClick={install}>
            安装
          </Button>
        ) : null}
        <Button variant="ghost" size="sm" className="min-h-11 flex-1 sm:min-h-0" onClick={dismiss}>
          暂不
        </Button>
      </div>
    </div>
  );
}
