import { apiDelete, apiGet, apiPost, withQuery } from "@/lib/api";
import type { Container, ContainerStat, ImageItem, NetworkItem, VolumeItem } from "@/lib/types";

export function listContainers(serverID: number) {
  return apiGet<Container[]>(`/api/servers/${serverID}/containers`);
}

export type ContainerAction = "start" | "stop" | "restart" | "rm";

export function containerAction(serverID: number, cid: string, action: ContainerAction) {
  return apiPost<{ container: string; action: string; output: string }>(
    `/api/servers/${serverID}/containers/${encodeURIComponent(cid)}/actions`,
    { action },
  );
}

export function containerStats(serverID: number) {
  return apiGet<ContainerStat[]>(`/api/servers/${serverID}/container-stats`);
}

export function listImages(serverID: number) {
  return apiGet<ImageItem[]>(`/api/servers/${serverID}/images`);
}

export function pullImage(serverID: number, reference: string) {
  return apiPost<{ image: string; output: string }>(`/api/servers/${serverID}/images/pull`, { image: reference });
}

export function removeImage(serverID: number, imageID: string) {
  return apiDelete<{ deleted: string; output: string }>(
    `/api/servers/${serverID}/images/${encodeURIComponent(imageID)}`,
  );
}

export function listNetworks(serverID: number) {
  return apiGet<NetworkItem[]>(`/api/servers/${serverID}/networks`);
}

export function listVolumes(serverID: number) {
  return apiGet<VolumeItem[]>(`/api/servers/${serverID}/volumes`);
}

/** 申请日志票（60s 一次性），用于建立 WebSocket。 */
export function createLogsTicket(serverID: number, cid: string) {
  return apiPost<{ ticket: string; expires_in: number }>(
    `/api/servers/${serverID}/containers/${encodeURIComponent(cid)}/logs-ticket`,
  );
}

/** 构造日志 WebSocket URL（走同源，开发期由 Vite 代理 ws）。 */
export function logsSocketURL(serverID: number, cid: string, ticket: string, tail = 200): string {
  const proto = window.location.protocol === "https:" ? "wss:" : "ws:";
  return withQuery(
    `${proto}//${window.location.host}/api/servers/${serverID}/containers/${encodeURIComponent(cid)}/logs`,
    { ticket, tail },
  );
}
