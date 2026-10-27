import { Navigate, Route, Routes } from "react-router-dom";

import { AppShell } from "@/components/AppShell";
import { LoginPage } from "@/pages/LoginPage";
import { PlaceholderPage } from "@/pages/PlaceholderPage";
import { RequireAuth } from "@/routes/RequireAuth";

/** 受保护区域统一套 AppShell。 */
function Shell({ children }: { children: React.ReactNode }) {
  return (
    <RequireAuth>
      <AppShell>{children}</AppShell>
    </RequireAuth>
  );
}

export function App() {
  return (
    <Routes>
      <Route path="/login" element={<LoginPage />} />

      <Route
        path="/"
        element={
          <Shell>
            <PlaceholderPage title="总览" note="服务器卡片与在线状态将在 M6.3 实现。" />
          </Shell>
        }
      />
      <Route
        path="/alerts"
        element={
          <Shell>
            <PlaceholderPage title="通知中心" note="告警列表与规则管理将在 M6.7 实现。" />
          </Shell>
        }
      />
      <Route
        path="/settings"
        element={
          <Shell>
            <PlaceholderPage title="设置" note="连接与告警设置将在后续实现。" />
          </Shell>
        }
      />

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
