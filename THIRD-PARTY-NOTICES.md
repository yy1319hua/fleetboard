# 第三方开源组件声明（THIRD-PARTY NOTICES）

本项目为 MIT 许可（见 `LICENSE`）。以下列出**直接依赖**的开源组件及其许可证。
完整依赖树（含间接依赖）见 `go.mod` / `go.sum`。

| 组件 | 版本 | 许可证 | 上游 |
| --- | --- | --- | --- |
| github.com/gin-gonic/gin | v1.10.0 | MIT | https://github.com/gin-gonic/gin |
| github.com/golang-jwt/jwt/v5 | v5.2.1 | MIT | https://github.com/golang-jwt/jwt |
| github.com/pkg/sftp | v1.13.6 | BSD-2-Clause | https://github.com/pkg/sftp |
| golang.org/x/crypto | v0.28.0 | BSD-3-Clause | https://cs.opensource.google/go/x/crypto |
| modernc.org/sqlite | v1.34.1 | BSD-3-Clause | https://gitlab.com/cznic/sqlite |

## 维护约定

- **新增任何开源依赖时，必须同步在本文件补充：组件名 / 版本 / 许可证 / 上游链接。**（见工作区 `HANDOFF.md` 工程红线）
- 许可证全文随各组件分发，可分别在上游仓库的 `LICENSE` 文件查阅。
- 若升级依赖版本，请同步更新本表版本号。
