/**
 * 统一 API 客户端。
 *
 * 约定：
 * - 后端统一响应 `{code,msg,data}`；成功 code=0，失败用 HTTP 状态码 + msg。
 * - access token 过期时自动用 refresh 换一次，再重放原请求（并发刷新只发一次）。
 * - 刷新失败则清空登录态并抛 ApiError(401)，由调用方/路由守卫跳登录页。
 */

export class ApiError extends Error {
  readonly status: number;
  readonly code: number;

  constructor(status: number, message: string, code = status) {
    super(message);
    this.name = "ApiError";
    this.status = status;
    this.code = code;
  }
}

interface AuthBridge {
  getAccess: () => string | null;
  getRefresh: () => string | null;
  onRefreshed: (access: string) => void;
  onAuthLost: () => void;
}

let bridge: AuthBridge = {
  getAccess: () => null,
  getRefresh: () => null,
  onRefreshed: () => {},
  onAuthLost: () => {},
};

/** 由 auth store 在启动时注入 token 读写能力（避免 lib 层反向依赖 store）。 */
export function configureAuth(next: AuthBridge): void {
  bridge = next;
}

/** 当前 access token（供需要自行发请求的场景，如带认证头的下载）。 */
export function currentAccessToken(): string | null {
  return bridge.getAccess();
}

interface ApiEnvelope<T> {
  code: number;
  msg: string;
  data?: T;
}

let refreshInFlight: Promise<string | null> | null = null;

async function refreshAccessToken(): Promise<string | null> {
  if (refreshInFlight) return refreshInFlight;

  refreshInFlight = (async () => {
    const refresh = bridge.getRefresh();
    if (!refresh) return null;

    try {
      const res = await fetch("/api/refresh", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ refresh_token: refresh }),
      });
      if (!res.ok) return null;

      const body = (await res.json()) as ApiEnvelope<{ access_token: string }>;
      const access = body.data?.access_token;
      if (!access) return null;

      bridge.onRefreshed(access);
      return access;
    } catch {
      return null;
    }
  })().finally(() => {
    refreshInFlight = null;
  });

  return refreshInFlight;
}

export interface RequestOptions {
  /** 是否附带 Authorization（公开端点传 false） */
  auth?: boolean;
  /** 允许 401 后自动刷新并重放一次（内部用，默认 true） */
  retryOn401?: boolean;
  signal?: AbortSignal;
}

/** 发起请求并解包 `data`；失败抛 ApiError。 */
export async function api<T>(
  path: string,
  init: RequestInit = {},
  opts: RequestOptions = {},
): Promise<T> {
  const { auth = true, retryOn401 = true } = opts;

  const headers = new Headers(init.headers);
  if (init.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  if (auth) {
    const access = bridge.getAccess();
    if (access) headers.set("Authorization", `Bearer ${access}`);
  }

  const res = await fetch(path, { ...init, headers, signal: opts.signal ?? init.signal });

  if (res.status === 401 && auth && retryOn401) {
    const fresh = await refreshAccessToken();
    if (fresh) {
      return api<T>(path, init, { auth, retryOn401: false, signal: opts.signal });
    }
    bridge.onAuthLost();
    throw new ApiError(401, "登录已过期，请重新登录", 401);
  }

  const text = await res.text();
  let body: ApiEnvelope<T> | null = null;
  if (text) {
    try {
      body = JSON.parse(text) as ApiEnvelope<T>;
    } catch {
      // 非 JSON（如网关错误页）：落到下方统一错误处理
      body = null;
    }
  }

  if (!res.ok) {
    throw new ApiError(res.status, body?.msg || `请求失败（HTTP ${res.status}）`, body?.code ?? res.status);
  }
  if (!body) {
    throw new ApiError(res.status, "响应为空或格式不正确", res.status);
  }
  return body.data as T;
}

/** 便捷方法：GET / POST / PUT / DELETE。 */
export const apiGet = <T>(path: string, opts?: RequestOptions) => api<T>(path, {}, opts);

export const apiPost = <T>(path: string, body?: unknown, opts?: RequestOptions) =>
  api<T>(path, { method: "POST", body: body === undefined ? undefined : JSON.stringify(body) }, opts);

export const apiPut = <T>(path: string, body?: unknown, opts?: RequestOptions) =>
  api<T>(path, { method: "PUT", body: body === undefined ? undefined : JSON.stringify(body) }, opts);

export const apiDelete = <T>(path: string, opts?: RequestOptions) =>
  api<T>(path, { method: "DELETE" }, opts);

/** 拼查询串：跳过 undefined/null 与空字符串。 */
export function withQuery(path: string, params: Record<string, string | number | boolean | undefined | null>): string {
  const usp = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) {
    if (v === undefined || v === null || v === "") continue;
    usp.set(k, String(v));
  }
  const q = usp.toString();
  return q ? `${path}?${q}` : path;
}
