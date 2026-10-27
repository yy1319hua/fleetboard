#!/usr/bin/env bash
# fleetboard 安装脚本（root 运行）
# 用法：sudo ./install.sh              交互式（管道安装时自动改走 /dev/tty，无终端则全自动生成）
#       预填配置：在同目录放 .env.filled（参考 .env.example）则跳过交互
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
# 架构校验：直接读 ELF 头 e_machine（62=amd64, 183=arm64），不依赖 file 等外部命令
elf_machine=$(od -An -j18 -N2 -tu2 "$SRC/fleetboard" | tr -d ' ')
case "$elf_machine" in
  62) built=amd64;; 183) built=arm64;;
  *) echo "无法识别二进制架构（e_machine=$elf_machine）"; exit 1;;
esac
[ "$built" = "$a" ] || { echo "二进制架构($built)与本机($a)不符，请换对应发布包"; exit 1; }

# ---- 收集必填配置 ----
# 优先级：已有 .env.filled > 交互输入（/dev/tty，兼容 curl|bash 管道安装）> 全自动生成
# 自动生成时账密会在安装完成处打印一次。
ENV_SRC="$SRC/.env.filled"
AUTOGEN=1
if [ -f "$ENV_SRC" ]; then
  echo "==> 检测到 .env.filled，使用其配置"
  AUTOGEN=0
else
  echo "==> 交互式填写配置（直接回车=自动生成/默认）"
  ask() { # ask <提示> <变量名>：提示写 /dev/tty（read -p 走 stderr，重定向下会被吞），输入也从终端读
    local v=""
    if { printf "%s" "$1" >/dev/tty && read -r v </dev/tty; } 2>/dev/null; then printf -v "$2" "%s" "$v"; else printf -v "$2" ""; fi
  }
  ask "管理员用户名 [admin]: " BU; BU=${BU:-admin}
  ask "管理员密码 [随机生成]: " BP; BP=${BP:-$(openssl rand -hex 8)}
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
  [ -t 0 ] || [ -e /dev/tty ] || echo "⚠️ 未检测到终端：已自动生成管理员账密，安装完成后会打印（只显示一次）"
fi

echo "==> 安装文件到 $BASE"
mkdir -p "$BASE" "$DATA"
install -m 755 "$SRC/fleetboard" "$BASE/fleetboard"
cp -r "$SRC/web-dist" "$BASE/web-dist"
install -m 600 "$ENV_SRC" "$BASE/.env"
cp "$SRC/uninstall.sh" "$BASE/uninstall.sh" && chmod +x "$BASE/uninstall.sh"

echo "==> 写入 systemd 单元"
install -m 644 "$SRC/fleetboard.service" "$UNIT"
systemctl daemon-reload

echo "==> 启动并设开机自启"
systemctl enable --now fleetboard

# 健康自检：最多等 10 秒
PORT_NUM=$(grep -E '^PORT=' "$BASE/.env" | cut -d= -f2); PORT_NUM=${PORT_NUM:-8080}
ok=""
for _ in $(seq 1 10); do
  if curl -fsS "http://127.0.0.1:$PORT_NUM/api/health" 2>/dev/null; then ok=1; echo; break; fi
  sleep 1
done
if [ -n "$ok" ]; then
  echo "==> 服务健康：http://127.0.0.1:$PORT_NUM（公网请在 Cloudflare Tunnel 指向此地址）"
else
  echo "❌ 健康检查未通过，请排查：journalctl -u fleetboard -n 50" >&2
  exit 1
fi

if [ "$AUTOGEN" = 1 ]; then
  echo "==> 自动生成的管理员账密（只显示这一次，请立即记录）："
  echo "    用户名: $BU"
  echo "    密  码: $BP"
fi
echo "==> 安装完成。卸载：sudo /opt/fleetboard/uninstall.sh"
