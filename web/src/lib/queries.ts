import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { apiDelete, apiGet, apiPost, apiPut } from "@/lib/api";
import type { Server, ServerFacts, ServerMetric } from "@/lib/types";

export const qk = {
  servers: ["servers"] as const,
  server: (id: number) => ["servers", id] as const,
  latestMetric: (id: number) => ["servers", id, "metric-latest"] as const,
  serverFacts: (id: number) => ["servers", id, "facts"] as const,
};

export function useServer(serverID: number) {
  return useQuery({
    queryKey: qk.server(serverID),
    queryFn: () => apiGet<Server>(`/api/servers/${serverID}`),
    enabled: serverID > 0,
  });
}

export function useServers() {
  return useQuery({
    queryKey: qk.servers,
    queryFn: () => apiGet<Server[]>("/api/servers"),
    refetchInterval: 30_000, // 与后端采集间隔一致，状态近实时
  });
}

/** 最新采样；404（暂无数据）视为 null，不当作错误。 */
export function useLatestMetric(serverID: number) {
  return useQuery({
    queryKey: qk.latestMetric(serverID),
    queryFn: async () => {
      try {
        return await apiGet<ServerMetric>(`/api/servers/${serverID}/metrics/latest`);
      } catch (err) {
        const status = (err as { status?: number }).status;
        if (status === 404) return null;
        throw err;
      }
    },
    refetchInterval: 30_000,
    enabled: serverID > 0,
  });
}

/**
 * 主机静态配置。404 表示后台还没采到（刚纳管 / 服务器离线），
 * 视为 null 让概览卡显示「等待采集」，而不是抛错让整页进错误态。
 * 配置变化很慢，5 分钟刷新一次足够。
 */
export function useServerFacts(serverID: number) {
  return useQuery({
    queryKey: qk.serverFacts(serverID),
    queryFn: async () => {
      try {
        return await apiGet<ServerFacts>(`/api/servers/${serverID}/facts`);
      } catch (err) {
        const status = (err as { status?: number }).status;
        if (status === 404) return null;
        throw err;
      }
    },
    refetchInterval: 300_000,
    enabled: serverID > 0,
  });
}

export interface CreateServerInput {
  name: string;
  host: string;
  port: number;
  ssh_user: string;
  auth_method: "key" | "password";
  private_key?: string;
  password?: string;
  key_pass?: string;
  tags?: string;
}

export function useCreateServer() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (input: CreateServerInput) => apiPost<Server>("/api/servers", input),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.servers });
    },
  });
}

/** 预检输入：编辑场景带 server_id，留空的字段（含凭据）由后端用库里值补齐。 */
export interface ProbeServerInput {
  host: string;
  port: number;
  ssh_user: string;
  auth_method: "key" | "password";
  private_key?: string;
  password?: string;
  key_pass?: string;
  server_id?: number;
}

export interface ProbeResult {
  ok: boolean;
  elapsed_ms: number;
}

/**
 * 试连但**不落库**。纳管流程靠它把「连不上」挡在写库之前：
 * 探不通时列表里不会出现一台永远连不上的机器。
 */
export function useProbeServer() {
  return useMutation({
    mutationFn: (input: ProbeServerInput) => apiPost<ProbeResult>("/api/servers/probe", input),
  });
}

export function useUpdateServer() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...input }: CreateServerInput & { id: number }) =>
      apiPut<Server>(`/api/servers/${id}`, input),
    onSuccess: (_data, vars) => {
      void qc.invalidateQueries({ queryKey: qk.servers });
      void qc.invalidateQueries({ queryKey: qk.server(vars.id) });
    },
  });
}

export function useDeleteServer() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => apiDelete<{ deleted: number }>(`/api/servers/${id}`),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.servers });
    },
  });
}

export interface TestResult {
  server_id: number;
  status: string;
}

export function useTestServer() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: number) => apiPost<TestResult>(`/api/servers/${id}/test`),
    onSuccess: () => {
      void qc.invalidateQueries({ queryKey: qk.servers });
    },
  });
}
