# fleetboard

![Go](https://img.shields.io/badge/Go-1.21-00ADD8?logo=go&logoColor=white) ![React](https://img.shields.io/badge/React-18-61DAFB?logo=react&logoColor=black) ![Vite](https://img.shields.io/badge/Vite-5-646CFF?logo=vite&logoColor=white) ![PWA](https://img.shields.io/badge/PWA-ready-5A0FC8?logo=pwa&logoColor=white) ![Flutter](https://img.shields.io/badge/Flutter-3.24-02569B?logo=flutter&logoColor=white) ![SQLite](https://img.shields.io/badge/SQLite-3-003B57?logo=sqlite&logoColor=white)
[![CI](https://github.com/yy1319hua/fleetboard/actions/workflows/ci.yml/badge.svg)](https://github.com/yy1319hua/fleetboard/actions/workflows/ci.yml) [![Release](https://img.shields.io/github/v/release/yy1319hua/fleetboard)](https://github.com/yy1319hua/fleetboard/releases) ![License](https://img.shields.io/github/license/yy1319hua/fleetboard)

个人自用的多服务器管理工具：**SSH 直连纳管**，统一管理文件、Docker 容器、主机监控与告警、Compose 配置与系统包更新；Web 与移动端（PWA）同构，共用一套后端 API。

> ⚠️ **声明**：本项目为**个人自用**，未经系统性安全审计与生产验证，按现状（AS-IS）提供。
> 安装/使用前请自行检查脚本与配置，切勿在重要业务环境直接套用。
> 目标机将以 root 或专用全权账号纳管，请自行评估风险。

## 设计要点

- **零配置纳管**：不在被管机安装 Agent，控制面经 SSH/SFTP 直连即可管理。
- **轻量单二进制**：Go + SQLite，单文件部署。
- **安全优先**：SSH 凭据 AES-256-GCM 加密存储（主密钥仅走环境变量）；`/api/*` 由 JWT 守护，公网仅经 Cloudflare Tunnel 暴露。
- **同构前端**：React + Vite + PWA，Web 与移动端共用一套代码。

## 安装（Linux amd64 / arm64）

### 一条命令（推荐）

```bash
curl -fsSL https://raw.githubusercontent.com/yy1319hua/fleetboard/main/deploy/install-remote.sh | sudo bash
```

自动完成：探测架构 → 从 Releases 下载最新版 → SHA256 校验 → 装到 `/opt/fleetboard` → systemd 起服务并设开机自启。过程中会交互式询问管理员用户名/密码，加密密钥自动生成。

> ⚠️ 管道执行前建议先 `curl -fsSL <同地址>` 通读脚本内容再运行。

### 手动安装

从 [Releases](https://github.com/yy1319hua/fleetboard/releases) 下载对应架构的 `fleetboard-*.tar.gz`，解压后：

```bash
sudo ./install.sh
```

### 升级

> ⚠️ 已安装的机器**严禁重跑 `install.sh`**（会刷新 KEY，已纳管凭据将无法解密）——重跑会被脚本拒绝。
> 升级一律走 `upgrade.sh`：自动备份 `.env`（不动）与数据库快照，旧二进制留 `fleetboard.prev`，health 校验失败自动回滚。

```bash
# 方式一：在线升级（下载最新 Release + SHA256 校验）
sudo ./upgrade.sh          # 也可指定版本：sudo ./upgrade.sh v0.1.3

# 方式二：离线升级（无外网机器，用已解包的新版发布目录）
sudo ./upgrade.sh /path/to/fleetboard-vX.Y.Z
```

远程一条命令在已安装机器上会自动改走升级流程。

### 布局与卸载

| 路径 | 内容 |
| --- | --- |
| `/opt/fleetboard/` | 二进制 + 前端产物 + `.env`（600） |
| `/var/lib/fleetboard/` | SQLite 数据（纳管记录、凭据密文） |
| `/etc/systemd/system/fleetboard.service` | systemd 单元 |

```bash
sudo /opt/fleetboard/…/uninstall.sh   # 或发布包内的 uninstall.sh
```

停服务 → 删程序目录与单元 → 数据目录需手动输入 `DELETE` 确认 → 末尾自动扫描残留，无散落文件。

### 升级

替换 `/opt/fleetboard/fleetboard` 与 `web-dist/` 后 `systemctl restart fleetboard`（数据不受影响）。

## 快速开始（开发）

```bash
# 1. 准备环境变量
cp .env.example .env
# 编辑 .env：至少填写 KEY 与 JWT_SECRET（openssl rand -hex 32）
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
| `JWT_SECRET` | 否 | 自动生成 | JWT 签名密钥；已入库 settings（首启吸收 env 原值，缺失自动生成），优先级 DB > env |
| `BOOTSTRAP_USER` | 否 | `admin` | 首次启动管理员用户名（users 空时生效） |
| `BOOTSTRAP_PASS` | 否 | 随机生成 | 首次启动管理员密码；缺省自动生成并打印日志（仅一次） |
| `MONITOR_INTERVAL` | 否 | `30` | 指标采集间隔（秒）；已入库 settings，运行期热生效 |
| `METRICS_RETENTION_DAYS` | 否 | `30` | 指标保留天数；已入库 settings，运行期热生效 |
| `OFFLINE_THRESHOLD` | 否 | `2` | 连续失败判定离线次数；已入库 settings，运行期热生效 |
| `PUSHPLUS_TOKEN` | 否 | — | PushPlus 告警 token；**已废弃为启动吸收值**——运行期改 token 请用设置面（M8.1b API / M8.1c UI），热生效 |

## 发布

打 tag 即自动发布（GitHub Actions 构建双架构二进制 + 前端并上传 Release）：

```bash
git tag v0.1.1 && git push origin v0.1.1
```

## 开发命令

```bash
make all      # fmt + vet + test + build
make test     # 单元测试
make lint     # gofmt 检查
make build    # 产出 bin/fleetboard
make release  # 测试通过后产出双架构发布包（deploy/release/）
```

> 编译与测试在本地开发机完成；提交与推送在 sanbox 工作区进行。

## 许可证

本项目采用 **MIT** 许可，见 [LICENSE](LICENSE)。
第三方开源组件及许可证见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。
