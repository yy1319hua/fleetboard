import "@fontsource-variable/geist";
import "@fontsource-variable/jetbrains-mono";

import "./index.css";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";

import { App } from "@/App";
import { useAuth } from "@/store/auth";

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      // 运维数据要"够新"：默认不缓存陈旧结果，失败不自动重试（SSH 慢，重试会放大等待）
      staleTime: 5_000,
      retry: 0,
      refetchOnWindowFocus: true,
    },
    mutations: {
      retry: 0,
    },
  },
});

// 登录态失效（含 401 自动刷新失败）时清空查询缓存，防止残留上一位的数据
useAuth.subscribe((state, prev) => {
  if (!state.access && prev.access) queryClient.clear();
});

const container = document.getElementById("root");
if (!container) {
  throw new Error("缺少 #root 挂载点");
}

createRoot(container).render(
  <StrictMode>
    <QueryClientProvider client={queryClient}>
      <BrowserRouter>
        <App />
      </BrowserRouter>
    </QueryClientProvider>
  </StrictMode>,
);
