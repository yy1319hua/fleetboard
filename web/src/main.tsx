import "@fontsource-variable/geist";
import "@fontsource-variable/jetbrains-mono";

import "./index.css";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { BrowserRouter } from "react-router-dom";

import { App } from "@/App";

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
