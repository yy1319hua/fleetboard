import { apiGet, apiPost, apiPut } from "@/lib/api";

/** 单个敏感项的掩码视图：GET 只回尾 4 位。 */
export interface SecretView {
  masked: string;
  set: boolean;
}

/** GET /api/settings 响应：items + 只读区。 */
export interface SettingsView {
  items: Record<string, string | SecretView>;
  readonly: {
    key_masked: string;
    port: number;
  } | null;
}

export function fetchSettings(): Promise<SettingsView> {
  return apiGet<SettingsView>("/api/settings");
}

/** PUT /api/settings：掩码/空值项后端自动跳过。 */
export function saveSettings(updates: Record<string, string>): Promise<SettingsView> {
  return apiPut<SettingsView>("/api/settings", updates);
}

/** POST /api/settings/test-channel：token 可传未保存的新值，空则测已存的。 */
export function testPushChannel(token?: string): Promise<{ sent: boolean }> {
  return apiPost<{ sent: boolean }>("/api/settings/test-channel", token ? { token } : {});
}
