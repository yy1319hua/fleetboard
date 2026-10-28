import { Navigate, Route, Routes } from "react-router-dom";

import { AppShell } from "@/components/AppShell";
import { AlertsPage } from "@/pages/AlertsPage";
import { DashboardPage } from "@/pages/DashboardPage";
import { LoginPage } from "@/pages/LoginPage";
import { ServerDetailPage } from "@/pages/ServerDetailPage";
import { ServerPackagesTab } from "@/pages/tabs/ServerPackagesTab";
import { ServerComposeTab } from "@/pages/tabs/ServerComposeTab";
import { ServerDockerTab } from "@/pages/tabs/ServerDockerTab";
import { ServerFilesTab } from "@/pages/tabs/ServerFilesTab";
import { ServerMonitorTab } from "@/pages/tabs/ServerMonitorTab";
import { ServerOverviewTab } from "@/pages/tabs/ServerOverviewTab";
import { SettingsPage } from "@/pages/SettingsPage";
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
        <Route path="compose" element={<ServerComposeTab />} />
        <Route path="packages" element={<ServerPackagesTab />} />
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
            <SettingsPage />
          </Shell>
        }
      />

      <Route path="*" element={<Navigate to="/" replace />} />
    </Routes>
  );
}
