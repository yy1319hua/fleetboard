import { apiGet, apiPost, apiPut, withQuery } from "@/lib/api";
import type { ComposeList } from "@/lib/types";

export function listCompose(serverID: number, dir?: string) {
  return apiGet<ComposeList>(withQuery(`/api/servers/${serverID}/compose`, { dir }));
}

export function readCompose(serverID: number, path: string) {
  return apiGet<{ path: string; content: string; size: number }>(
    withQuery(`/api/servers/${serverID}/compose/content`, { path }),
  );
}

export function writeCompose(serverID: number, path: string, content: string) {
  return apiPut<{ path: string; size: number }>(`/api/servers/${serverID}/compose/content`, { path, content });
}

export type ComposeAction = "up" | "down" | "restart" | "ps";

export function composeAction(serverID: number, path: string, action: ComposeAction) {
  return apiPost<{ path: string; action: string; output: string }>(
    `/api/servers/${serverID}/compose/actions`,
    { path, action },
  );
}

export const COMPOSE_ACTION_LABEL: Record<ComposeAction, string> = {
  up: "启动 (up -d)",
  down: "停止 (down)",
  restart: "重启",
  ps: "查看状态 (ps)",
};
