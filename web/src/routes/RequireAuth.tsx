import type { ReactNode } from "react";
import { Navigate, useLocation } from "react-router-dom";

import { useAuth } from "@/store/auth";

/**
 * 路由守卫：未登录跳登录页，并记住来路以便登录后回跳。
 *
 * 必须订阅 store 而不是调用 isAuthenticated()：token 失效时 api 层会 logout，
 * 非订阅式读取不会触发重渲染，页面会停在原地继续 401，永远不回登录页。
 */
export function RequireAuth({ children }: { children: ReactNode }) {
  const location = useLocation();
  const authenticated = useAuth((s) => !!s.access);

  if (!authenticated) {
    return <Navigate to="/login" replace state={{ from: location.pathname + location.search }} />;
  }
  return <>{children}</>;
}
