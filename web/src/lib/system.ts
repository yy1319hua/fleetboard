import { apiGet, apiPost } from "@/lib/api";

/**
 * 面板自更新 / 审计 / 当前账号 / 健康检查。
 *
 * 全部端点自 v0.4.0 起就存在（`internal/api/router.go`），Web 此前零调用；
 * 本轮只补前端入口，不改后端、不升服务端版本。
 */

/** GET /api/system/upgrade：只读，无副作用。连版本检查都要用户手动触发。 */
export interface UpgradeInfo {
  current_version: string;
  latest_version: string;
  upgrade_enabled: boolean;
  can_upgrade: boolean;
  reason: string;
  last: UpgradeRecord | null;
}

/** GET /api/system/upgrade/status：升级进度与日志尾。 */
export interface UpgradeStatus {
  state: string;
  phase_text: string;
  from: string;
  to: string;
  error_code: string;
  log_tail: string[];
}

/** 一条升级记录（GET /api/system/upgrades）。 */
export interface UpgradeRecord {
  id: number;
  from_version: string;
  to_version: string;
  status: string;
  started_at: string;
  finished_at: string | null;
  duration_ms: number;
  error_code: string;
  triggered_by: number | null;
  log_path: string;
}

/** 一条操作审计（GET /api/audit?limit=N）。 */
export interface AuditEntry {
  id: number;
  user_id: number;
  server_id: number | null;
  action: string;
  detail: string;
  result: string;
  created_at: string;
}

/** GET /api/health：公开端点，返回面板版本与 schema 版本。 */
export interface HealthInfo {
  status: string;
  version: string;
  schema: number;
  config_rev?: number;
}

/** GET /api/me：当前登录账号。 */
export interface MeInfo {
  id: number;
  username: string;
}

export function fetchMe(): Promise<MeInfo> {
  return apiGet<MeInfo>("/api/me");
}

/**
 * POST /api/auth/change-username。
 * 入参 `{new_username, current_password}`；改名**不换 token、不 bump JWT ver**，
 * 当前会话与其他已登录端都无感。
 */
export function changeUsername(newUsername: string, currentPassword: string): Promise<unknown> {
  return apiPost("/api/auth/change-username", {
    new_username: newUsername,
    current_password: currentPassword,
  });
}

export function fetchUpgradeInfo(): Promise<UpgradeInfo> {
  return apiGet<UpgradeInfo>("/api/system/upgrade");
}

export function fetchUpgradeStatus(): Promise<UpgradeStatus> {
  return apiGet<UpgradeStatus>("/api/system/upgrade/status");
}

/** POST /api/system/upgrade：必须人工触发，要当前账号密码 + 目标版本。 */
export function triggerUpgrade(password: string, targetVersion: string): Promise<unknown> {
  return apiPost("/api/system/upgrade", {
    password,
    target_version: targetVersion,
  });
}

export function fetchUpgradeHistory(): Promise<UpgradeRecord[]> {
  return apiGet<UpgradeRecord[]>("/api/system/upgrades");
}

/** 后端只支持 limit（无 offset / 筛选），所以页面只做「窗口加大」，不造假分页。 */
export function fetchAudit(limit = 50): Promise<AuditEntry[]> {
  return apiGet<AuditEntry[]>(`/api/audit?limit=${limit}`);
}

export function fetchHealth(): Promise<HealthInfo> {
  return apiGet<HealthInfo>("/api/health");
}
