import type { ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import { NavLink, useNavigate } from "react-router-dom";

import { IconBell, IconGear, IconGrid, IconLogout } from "@/components/icons";
import { useAuth } from "@/store/auth";
import { cn } from "@/lib/cn";

interface NavItem {
  to: string;
  label: string;
  icon: ReactNode;
  /** 仅移动端底部 Tab 显示 */
  mobile?: boolean;
}

const NAV: NavItem[] = [
  { to: "/", label: "总览", icon: <IconGrid />, mobile: true },
  { to: "/alerts", label: "通知", icon: <IconBell />, mobile: true },
  { to: "/settings", label: "设置", icon: <IconGear />, mobile: true },
];

/**
 * 应用外壳：桌面左栏 216px + 内容区；移动端底部 Tab（DESIGN.md 第 4/8 节）。
 * 移动端不隐藏任何功能入口——全部页面可达（用户已确认以 App 为主）。
 */
export function AppShell({ children }: { children: ReactNode }) {
  const logout = useAuth((s) => s.logout);
  const username = useAuth((s) => s.username);
  const navigate = useNavigate();
  const queryClient = useQueryClient();

  const handleLogout = () => {
    // 先清缓存再清登录态，避免下一位看到上一轮的服务端数据
    queryClient.clear();
    logout();
    navigate("/login", { replace: true });
  };

  return (
    <div className="flex min-h-full flex-col bg-bg lg:flex-row">
      {/* 桌面侧栏 */}
      <aside className="hidden w-[216px] shrink-0 border-r border-border bg-surface-1 lg:flex lg:flex-col">
        <div className="flex h-14 items-center gap-2 border-b border-border px-4">
          <span className="inline-block h-2 w-2 rounded-full bg-accent" aria-hidden="true" />
          <span className="text-h3 tracking-tight text-text">fleetboard</span>
        </div>

        <nav className="flex-1 space-y-0.5 p-2" aria-label="主导航">
          {NAV.map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.to === "/"}
              className={({ isActive }) =>
                cn(
                  "relative flex items-center gap-2.5 rounded-control px-2.5 py-2 text-body transition-colors duration-ui ease-ui",
                  isActive
                    ? "bg-accent-soft text-text before:absolute before:left-0 before:top-1.5 before:bottom-1.5 before:w-0.5 before:rounded-full before:bg-accent"
                    : "text-text-muted hover:bg-surface-2 hover:text-text",
                )
              }
            >
              {item.icon}
              {item.label}
            </NavLink>
          ))}
        </nav>

        <div className="border-t border-border p-2">
          <div className="px-2.5 py-1.5 text-caption text-text-faint">
            {username ? `已登录：${username}` : "未登录"}
          </div>
          <button
            type="button"
            onClick={handleLogout}
            className="flex w-full items-center gap-2.5 rounded-control px-2.5 py-2 text-body text-text-muted transition-colors duration-ui ease-ui hover:bg-surface-2 hover:text-text"
          >
            <IconLogout />
            退出登录
          </button>
        </div>
      </aside>

      {/* 移动端顶栏 */}
      <header className="flex h-12 items-center justify-between border-b border-border bg-surface-1 px-3 lg:hidden">
        <div className="flex items-center gap-2">
          <span className="inline-block h-2 w-2 rounded-full bg-accent" aria-hidden="true" />
          <span className="text-h3 tracking-tight text-text">fleetboard</span>
        </div>
        <button
          type="button"
          onClick={handleLogout}
          aria-label="退出登录"
          className="flex h-11 w-11 items-center justify-center rounded-control text-text-muted hover:bg-surface-2 hover:text-text"
        >
          <IconLogout />
        </button>
      </header>

      {/* 内容区：移动端为底部 Tab 预留安全区 */}
      <main className="min-w-0 flex-1 pb-[calc(56px+env(safe-area-inset-bottom))] lg:pb-0">
        <div className="mx-auto w-full max-w-[1440px] px-3 py-4 sm:px-5 sm:py-6">{children}</div>
      </main>

      {/* 移动端底部 Tab */}
      <nav
        aria-label="底部导航"
        className="fixed inset-x-0 bottom-0 z-20 border-t border-border bg-surface-1 pb-[env(safe-area-inset-bottom)] lg:hidden"
      >
        <div className="flex">
          {NAV.filter((i) => i.mobile).map((item) => (
            <NavLink
              key={item.to}
              to={item.to}
              end={item.to === "/"}
              className={({ isActive }) =>
                cn(
                  "flex flex-1 flex-col items-center justify-center gap-0.5 py-2 text-caption transition-colors duration-ui ease-ui",
                  isActive ? "text-accent" : "text-text-muted",
                )
              }
            >
              {item.icon}
              {item.label}
            </NavLink>
          ))}
        </div>
      </nav>
    </div>
  );
}
