#!/usr/bin/env bash
# fleetboard 安装脚本（root 运行）
# 用法：./install.sh [--user NAME --pass PASS --key HEX --jwt HEX]
#   不带参数 = 交互式（或要求先填好同目录下已填好的 .env）
# 布局（卸载时按此回收，无散落文件）：
#   /opt/fleetboard/            二进制 + web-dist + .env
#   /var/lib/fleetboard/        SQLite 数据
#   /etc/systemd/system/fleetboard.service
set -euo pipefail

BASE=/opt/fleetboard
DATA=/var/lib/fleetboard
UNIT=/etc/systemd/system/fleetboard.service
SRC="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
[ -x "$SRC/fleetboard" ] || { echo "缺二进制 fleetboard"; exit 1; }
[ -f "$SRC/web-dist/index.html" ] || { echo "缺 web-dist/"; exit 1; }

ARCH=$(uname -m); case "$ARCH" in x86_64) a=amd64;; aarch64) a=arm64;; *) echo "不支持的架构 $ARCH"; exit 1;; esac
# 架构校验：直接读 ELF 头 e_machine（62=amd64, 183=arm64），不依赖 file/外部命令
elf_machine=$(od -An -j18 -N2 -tu2 "$SRC/fleetboard" | tr -d ' ')
case "$elf_machine" in
  62) built=amd64;; 183) built=arm64;;
  *) echo "无法识别二进制架构（e_machine=$elf_machine）"; exit 1;;
esac
[ "$built" = "$a" ] || { echo "二进制架构($built)与本机($a)不符，请换对应发布包"; exit 1; }

# ---- 收集必填配置 ----
ENV_SRC="$SRC/.env.filled"
if [ $# -eq 0 ] && [ ! -f "$ENV_SRC" ]; then
  echo "==> 交互式填写配置（直接回车=自动生成/默认）"
  read -rp "管理员用户名 [admin]: " BU; BU=${BU:-admin}
  read -rp "管理员密码 [随机生成]: " BP; BP=${BP:-$(openssl rand -hex 8)}
  KEY=${KEY:-$(openssl rand -hex 32)}
  JWT=${JWT:-$(openssl rand -hex 32)}
  cat > "$ENV_SRC" <<EOF
KEY=$KEY
JWT_SECRET=$JWT
BOOTSTRAP_USER=$BU
BOOTSTRAP_PASS=$BP
LISTEN_ADDR=127.0.0.1
PORT=8080
DATA_DIR=$DATA
WEB_DIR=$BASE/web-dist
EOF
fi
ENV_FILE="${ENV_SRC:-$SRC/.env.filled}"

echo "==> 安装文件到 $BASE"
mkdir -p "$BASE" "$DATA"
install -m 755 "$SRC/fleetboard" "$BASE/fleetboard"
cp -r "$SRC/web-dist" "$BASE/web-dist"
install -m 600 "$ENV_FILE" "$BASE/.env"

echo "==> 写入 systemd 单元"
install -m 644 "$SRC/fleetboard.service" "$UNIT"
systemctl daemon-reload

echo "==> 启动并设开机自启"
systemctl enable --now fleetboard
sleep 1
systemctl --no-pager --lines 3 status fleetboard || true
curl -fsS "http://127.0.0.1:8080/api/health" && echo && echo "==> 安装完成：服务已监听 127.0.0.1:8080，请在 Cloudflare Tunnel 指向此地址"
