# 第三方开源组件声明（THIRD-PARTY NOTICES）

本项目为 MIT 许可（见 `LICENSE`）。以下列出**直接依赖**的开源组件及其许可证。
完整依赖树（含间接依赖）见 `go.mod` / `go.sum` 与 `web/package.json` / `web/package-lock.json`。

## 后端（Go）

| 组件 | 版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| github.com/gin-gonic/gin | v1.10.0 | MIT | https://github.com/gin-gonic/gin |
| github.com/golang-jwt/jwt/v5 | v5.2.1 | MIT | https://github.com/golang-jwt/jwt |
| github.com/pkg/sftp | v1.13.6 | BSD-2-Clause | https://github.com/pkg/sftp |
| golang.org/x/crypto | v0.28.0 | BSD-3-Clause | https://cs.opensource.google/go/x/crypto |
| modernc.org/sqlite | v1.34.1 | BSD-3-Clause | https://gitlab.com/cznic/sqlite |

## 前端运行时依赖（`web/`）

| 组件 | 版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| react | 18.3.1 | MIT | https://github.com/facebook/react |
| react-dom | 18.3.1 | MIT | https://github.com/facebook/react |
| react-router-dom | 6.30.6 | MIT | https://github.com/remix-run/react-router |
| zustand | 5.0.16 | MIT | https://github.com/pmndrs/zustand |
| @tanstack/react-query | 5.105.0 | MIT | https://github.com/TanStack/query |
| recharts | 2.15.4 | MIT | https://github.com/recharts/recharts |
| @uiw/react-codemirror | 4.25.12 | MIT | https://github.com/uiwjs/react-codemirror |
| codemirror | 6.0.2 | MIT | https://github.com/codemirror/codemirror |
| @codemirror/lang-yaml | 6.1.3 | MIT | https://github.com/codemirror/lang-yaml |
| @fontsource-variable/geist | 5.3.0 | OFL-1.1 | https://github.com/fontsource-variable/geist-font |
| @fontsource-variable/jetbrains-mono | 5.3.0 | OFL-1.1 | https://github.com/fontsource-variable/jetbrains-mono |

## 前端构建期依赖（`web/`，devDependencies）

| 组件 | 版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| vite | 5.4.21 | MIT | https://github.com/vitejs/vite |
| @vitejs/plugin-react | 4.7.0 | MIT | https://github.com/vitejs/vite-plugin-react |
| vite-plugin-pwa | 0.20.5 | MIT | https://github.com/vite-pwa/vite-plugin-pwa |
| typescript | 5.9.3 | Apache-2.0 | https://github.com/microsoft/TypeScript |
| tailwindcss | 3.4.19 | MIT | https://github.com/tailwindlabs/tailwindcss |
| postcss | 8.5.32 | MIT | https://github.com/postcss/postcss |
| autoprefixer | 10.6.2 | MIT | https://github.com/postcss/autoprefixer |
| @types/react | 18.3.31 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |
| @types/react-dom | 18.3.7 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |
| @types/node | 22.20.5 | MIT | https://github.com/DefinitelyTyped/DefinitelyTyped |

## 维护约定

- **新增任何开源依赖时，必须同步在本文件补充：组件名 / 版本 / 许可证 / 上游链接。**（见工作区 `HANDOFF.md` 工程红线）
- 许可证全文随各组件分发，可分别在上游仓库的 `LICENSE` 文件查阅。
- 若升级依赖版本，请同步更新本表版本号。
