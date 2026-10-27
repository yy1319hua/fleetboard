import { Navigate, Route, Routes } from "react-router-dom";

import { AppShell } from "@/components/AppShell";
import { AlertsPage } from "@/pages/AlertsPage";
import { DashboardPage } from "@/pages/DashboardPage";
import { LoginPage } from "@/pages/LoginPage";
import { PlaceholderPage } from "@/pages/PlaceholderPage";
import { ServerDetailPage } from "@/pages/ServerDetailPage";
import { ServerDockerTab } from "@/pages/tabs/ServerDockerTab";
import { ServerFilesTab } from "@/pages/tabs/ServerFilesTab";
import { ServerMonitorTab } from "@/pages/tabs/ServerMonitorTab";
import { ServerOverviewTab } from "@/pages/tabs/ServerOverviewTab";
import { TabPlaceholder } from "@/pages/tabs/TabPlaceholder";
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
            <DashboardPage />
          </Shell>
        }
      />

      <Route
        path="/servers/:id"
        element={
          <Shell>
            <ServerDetailPage />
          </Shell>
        }
      >
        <Route index element={<ServerOverviewTab />} />
        <Route path="monitor" element={<ServerMonitorTab />} />
        <Route path="docker" element={<ServerDockerTab />} />
        <Route
          path="files"
          element={<ServerFilesTab />}
        />
        <Route
          path="compose"
          element={<TabPlaceholder title="Compose" note="compose 文件浏览、编辑与启停将在 M6.8 实现。" />}
        />
        <Route
          path="packages"
          element={<TabPlaceholder title="软件包更新" note="apt 流式更新面板将在 M6.9 实现。" />}
        />
      </Route>

      <Route
        path="/alerts"
        element={
          <Shell>
            <AlertsPage />
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
