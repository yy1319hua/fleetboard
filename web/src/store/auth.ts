import { create } from "zustand";

import { apiPost, configureAuth } from "@/lib/api";
import type { TokenPair } from "@/lib/types";

/**
 * 登录态。
 *
 * 存储位置：localStorage（个人自用工具，权衡后接受 XSS 面）。
 * 待改进：refresh token 改由后端 httpOnly Cookie 下发，前端不落盘 —— 已记入 HANDOFF 技术债。
 */

const STORAGE_KEY = "fleetboard.auth";

interface Persisted {
  access: string | null;
  refresh: string | null;
  username: string | null;
}

function readPersisted(): Persisted {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return { access: null, refresh: null, username: null };
    const parsed = JSON.parse(raw) as Partial<Persisted>;
    return {
      access: typeof parsed.access === "string" ? parsed.access : null,
      refresh: typeof parsed.refresh === "string" ? parsed.refresh : null,
      username: typeof parsed.username === "string" ? parsed.username : null,
    };
  } catch {
    return { access: null, refresh: null, username: null };
  }
}

function persist(state: Persisted): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(state));
  } catch {
    // 隐私模式/配额满：忽略，内存态仍可用，仅刷新后需重新登录
  }
}

interface AuthState extends Persisted {
  loggingIn: boolean;
  /** 登录失败信息（供表单展示，成功后清空） */
  error: string | null;
  login: (username: string, password: string) => Promise<void>;
  logout: () => void;
  /** 由 api 层在自动刷新成功后回写 */
  setAccess: (access: string) => void;
  clearError: () => void;
}

const initial = readPersisted();

export const useAuth = create<AuthState>((set, get) => ({
  ...initial,
  loggingIn: false,
  error: null,

  async login(username, password) {
    set({ loggingIn: true, error: null });
    try {
      const tokens = await apiPost<TokenPair>(
        "/api/login",
        { username, password },
        { auth: false },
      );
      const next: Persisted = {
        access: tokens.access_token,
        refresh: tokens.refresh_token ?? null,
        username,
      };
      persist(next);
      set({ ...next, loggingIn: false });
    } catch (err) {
      const message = err instanceof Error ? err.message : "登录失败";
      set({ loggingIn: false, error: message });
      throw err;
    }
  },

  logout() {
    persist({ access: null, refresh: null, username: null });
    set({ access: null, refresh: null, username: null, error: null });
  },

  setAccess(access) {
    const { refresh, username } = get();
    persist({ access, refresh, username });
    set({ access });
  },

  clearError() {
    set({ error: null });
  },
}));

// 把 token 读写能力注入 api 层（单向依赖：store -> api）
configureAuth({
  getAccess: () => useAuth.getState().access,
  getRefresh: () => useAuth.getState().refresh,
  onRefreshed: (access) => useAuth.getState().setAccess(access),
  onAuthLost: () => useAuth.getState().logout(),
});

/** 是否已登录（仅判断本地是否持有 access token，真实有效性由后端判定）。 */
export const isAuthenticated = (): boolean => Boolean(useAuth.getState().access);
