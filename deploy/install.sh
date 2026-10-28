#!/usr/bin/env bash
# fleetboard 安装脚本（root 运行）
# 用法：sudo ./install.sh
# 管理员账密：首次启动自举（M8.1a）——BOOTSTRAP_* 缺省时服务自动生成随机账密并打印到日志（仅一次），
#             安装完成处会自动提取展示；也可 journalctl -u fleetboard | grep 自举 查看
# 布局（卸载时按此回收，无散落文件）：
#   /opt/fleetboard/            二进制 + web-dist + .env
#   /var/lib/fleetboard/        SQLite 数据
#   /etc/systemd/system/fleetboard.service
set -euo pipefail

BASE=${FLEETBOARD_BASE:-/opt/fleetboard}
DATA=${FLEETBOARD_DATA:-/var/lib/fleetboard}
UNIT=${FLEETBOARD_UNIT:-/etc/systemd/system/fleetboard.service}
SRC="$(cd "$(dirname "$0")" && pwd)"

[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
[ -x "$SRC/fleetboard" ] || { echo "缺二进制 fleetboard"; exit 1; }
[ -f "$SRC/web-dist/index.html" ] || { echo "缺 web-dist/"; exit 1; }

# 防误装：已安装则拒绝——重跑安装会重新生成 KEY，已纳管凭据将全部无法解密
if [ -f "$BASE/.env" ]; then
  echo "❌ 检测到已安装（$BASE/.env 已存在）。"
  echo "   重跑安装会刷新 KEY，已存凭据将无法解密。"
  echo "   升级请用发布包内 upgrade.sh：sudo ./upgrade.sh"
  exit 1
fi

ARCH=$(uname -m); case "$ARCH" in x86_64) a=amd64;; aarch64) a=arm64;; *) echo "不支持的架构 $ARCH"; exit 1;; esac
# 架构校验：直接读 ELF 头 e_machine（62=amd64, 183=arm64），不依赖 file 等外部命令
elf_machine=$(od -An -j18 -N2 -tu2 "$SRC/fleetboard" | tr -d ' ')
case "$elf_machine" in
  62) built=amd64;; 183) built=arm64;;
  *) echo "无法识别二进制架构（e_machine=$elf_machine）"; exit 1;;
esac
[ "$built" = "$a" ] || { echo "二进制架构($built)与本机($a)不符，请换对应发布包"; exit 1; }

# ---- 生成 .env（M8.1a：收敛到 KEY + 不可热生效路径项；账密由首启自举）----
ENV_SRC="$SRC/.env.filled"
if [ ! -f "$ENV_SRC" ]; then
  KEY=${KEY:-$(openssl rand -hex 32)}
  cat > "$ENV_SRC" <<ENVEOF
KEY=$KEY
LISTEN_ADDR=127.0.0.1
PORT=8080
DATA_DIR=$DATA
WEB_DIR=$BASE/web-dist
ENVEOF
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

REG_HINT="手动纳管：Web 服务器页添加 127.0.0.1，私钥用 $BASE/id_local"
echo "==> 提取首次启动自举账密（仅显示这一次，请立即记录）："
sleep 1
BOOT_LOG=$(journalctl -u fleetboard -n 50 --no-pager 2>/dev/null | grep "首次启动自举" | tail -1 || true)
if [ -n "$BOOT_LOG" ]; then
  echo "    ${BOOT_LOG#*首次启动自举：}"
else
  echo "    （未从日志提取到，请手动执行：journalctl -u fleetboard | grep 自举）"
fi

# ---- 本机自动纳管（M8.3）：id_local 密钥对 + authorized_keys 标记 + API 注册 127.0.0.1 ----
KEY_TAG="fleetboard-local"
AUTHKEYS=${FLEETBOARD_AUTHKEYS:-/root/.ssh/authorized_keys}
if command -v ssh-keygen >/dev/null 2>&1 && [ ! -f "$BASE/id_local" ]; then
  echo "==> 本机自动纳管：生成 id_local 密钥对"
  ssh-keygen -t ed25519 -N "" -C "$KEY_TAG" -f "$BASE/id_local" -q
  mkdir -p "$(dirname "$AUTHKEYS")" && chmod 700 "$(dirname "$AUTHKEYS")"
  touch "$AUTHKEYS" && chmod 600 "$AUTHKEYS"
  grep -q "$KEY_TAG" "$AUTHKEYS" || cat "$BASE/id_local.pub" >> "$AUTHKEYS"
fi

if command -v python3 >/dev/null 2>&1 && [ -f "$BASE/id_local" ]; then
  CREDS=${BOOT_LOG#*已生成管理员账密 }
  CREDS=${CREDS%%（*}
  REG_USER=${CREDS%% /*}
  REG_PASS=${CREDS#* / }
  if [ -n "$REG_USER" ] && [ -n "$REG_PASS" ]; then
    M83_PORT=${FLEETBOARD_LOCAL_SSH_PORT:-22}
    if python3 - "$REG_USER" "$REG_PASS" "$PORT_NUM" "$BASE/id_local" "$M83_PORT" <<'REGEOF'
import json, sys, urllib.request
user, password, port, keypath, ssh_port = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
base = "http://127.0.0.1:" + port
def post(path, payload, token=None):
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = "Bearer " + token
    req = urllib.request.Request(base + path, data=json.dumps(payload).encode(), headers=headers, method="POST")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())
token = post("/api/login", {"username": user, "password": password})["data"]["access_token"]
key = open(keypath).read()
post("/api/servers", {"name": "本机", "host": "127.0.0.1", "port": ssh_port,
                      "ssh_user": "root", "auth_method": "key",
                      "private_key": key, "tags": "local"}, token)
print("本机已自动注册（127.0.0.1, tags=local）")
REGEOF
    then
      echo "==> 本机自动纳管完成"
    else
      echo "⚠️ 本机自动注册失败（服务可能未就绪），$REG_HINT"
    fi
  else
    echo "==> 本机自动纳管：账密来自 BOOTSTRAP_*，无法代登录，$REG_HINT"
  fi
else
  echo "==> 本机自动纳管：缺 python3 或密钥，$REG_HINT"
fi

echo "==> 安装完成。卸载：sudo /opt/fleetboard/uninstall.sh"
