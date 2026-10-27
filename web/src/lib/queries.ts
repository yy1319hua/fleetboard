import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";

import { apiDelete, apiGet, apiPost } from "@/lib/api";
import type { Server, ServerMetric } from "@/lib/types";

export const qk = {
  servers: ["servers"] as const,
  server: (id: number) => ["servers", id] as const,
  latestMetric: (id: number) => ["servers", id, "metric-latest"] as const,
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
