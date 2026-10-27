import { fileURLToPath, URL } from "node:url";

import react from "@vitejs/plugin-react";
import { defineConfig, loadEnv } from "vite";
import { VitePWA } from "vite-plugin-pwa";

export default defineConfig(({ mode }) => {
  // 开发期把 /api 代理到本地 Go 服务，避免跨域；生产由同源后端直出。
  const env = loadEnv(mode, process.cwd(), "");
  const apiTarget = env.VITE_API_TARGET || "http://127.0.0.1:8080";

  return {
    // 与 tsconfig 的 paths 保持一致：@ -> src
    resolve: {
      alias: {
        "@": fileURLToPath(new URL("./src", import.meta.url)),
      },
    },
    plugins: [
      react(),
      VitePWA({
        registerType: "autoUpdate",
        // 只预缓存应用壳与静态资源；接口数据一律不入缓存（运维数据不可陈旧）
        workbox: {
          globPatterns: ["**/*.{js,css,html,woff2,svg,png,ico}"],
          navigateFallbackDenylist: [/^\/api\//],
          runtimeCaching: [],
        },
        manifest: {
          name: "fleetboard",
          short_name: "fleetboard",
          description: "个人多服务器运维控制台",
          lang: "zh-CN",
          start_url: "/",
          scope: "/",
          display: "standalone",
          background_color: "#0f1115",
          theme_color: "#0f1115",
          icons: [
            { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
            { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
            {
              src: "/icons/icon-512-maskable.png",
              sizes: "512x512",
              type: "image/png",
              purpose: "maskable",
            },
          ],
        },
      }),
    ],
    server: {
      port: 5173,
      proxy: {
        "/api": {
          target: apiTarget,
          changeOrigin: false,
          ws: true,
        },
      },
    },
    build: {
      outDir: "dist",
      sourcemap: false,
    },
  };
});
