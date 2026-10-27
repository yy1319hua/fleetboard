# fleetboard

个人自用的多服务器管理工具：**SSH 直连纳管**，统一管理文件、Docker 容器、主机监控与告警、Compose 配置与系统包更新；Web 与移动端（PWA）同构，共用一套后端 API。

> 当前处于 **M0 脚手架** 阶段，尚无可用功能。

## 设计要点

- **零配置纳管**：不在被管机安装 Agent，控制面经 SSH/SFTP 直连即可管理。
- **轻量单二进制**：Go + SQLite，单文件部署。
- **安全优先**：SSH 凭据 AES-256-GCM 加密存储（主密钥仅走环境变量）；全站 HTTPS；`/api/*` 由 JWT 守护。
- **同构前端**：React + Vite + PWA，Web 与移动端共用一套代码。

## 快速开始

```bash
# 1. 准备环境变量
cp .env.example .env
# 编辑 .env：至少填写 KEY 与 JWT_SECRET（openssl rand -base64 32）
# 首次启动可按需填写 BOOTSTRAP_USER / BOOTSTRAP_PASS

# 2. 运行
make run
# 或
go run ./cmd/server

# 3. 健康检查
curl http://127.0.0.1:8080/api/health
```

## 环境变量

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `LISTEN_ADDR` | 否 | `127.0.0.1` | 监听地址（公网仅经 Cloudflare Tunnel） |
| `PORT` | 否 | `8080` | 监听端口 |
| `DATA_DIR` | 否 | `./data` | 数据目录 |
| `DB_PATH` | 否 | `$DATA_DIR/fleetboard.db` | SQLite 路径 |
| `KEY` | **是** | — | 凭据加密主密钥（AES-256-GCM） |
| `JWT_SECRET` | **是** | — | JWT 签名密钥 |
| `BOOTSTRAP_USER` | 否 | — | 首次启动管理员用户名 |
| `BOOTSTRAP_PASS` | 否 | — | 首次启动管理员密码 |
| `MONITOR_INTERVAL` | 否 | `30` | 指标采集间隔（秒） |
| `METRICS_RETENTION_DAYS` | 否 | `30` | 指标保留天数 |
| `OFFLINE_THRESHOLD` | 否 | `3` | 连续失败判定离线次数 |
| `PUSHPLUS_TOKEN` | 否 | — | PushPlus 告警 token |

## 开发命令

```bash
make all     # fmt + vet + test + build
make test    # 单元测试
make lint    # gofmt 检查
make build   # 产出 bin/fleetboard
```

> 编译与测试在本地开发机完成；提交与推送在 sanbox 工作区进行。

## 许可证

本项目采用 **MIT** 许可，见 [LICENSE](LICENSE)。
第三方开源组件及许可证见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
