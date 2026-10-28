#!/usr/bin/env bash
# fleetboard 安全升级脚本（root 运行）
# 用法：sudo ./upgrade.sh                      —— 拉取最新 Release（下载 + SHA256 校验）
#       sudo ./upgrade.sh v0.1.3               —— 固定版本
#       sudo ./upgrade.sh /path/to/fleetboard-* —— 离线升级：直接用本地已解包的发布目录
# 动作：停服务 → 备份 DB（VACUUM INTO，无 sqlite3 则连 WAL/SHM 一起拷）→ 旧二进制留 fleetboard.prev
#       → 换二进制与 web-dist（.env 与数据库一律不动）→ 起服务 → health 校验（失败自动回滚）
# 布局同 install.sh：/opt/fleetboard  /var/lib/fleetboard  /etc/systemd/system/fleetboard.service
set -euo pipefail

BASE=${FLEETBOARD_BASE:-/opt/fleetboard}
DATA=${FLEETBOARD_DATA:-/var/lib/fleetboard}
REPO="yy1319hua/fleetboard"

[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }
[ -f "$BASE/.env" ] || { echo "未检测到已安装（缺 $BASE/.env），请先用 install.sh 安装"; exit 1; }
[ -x "$BASE/fleetboard" ] || { echo "缺 $BASE/fleetboard，无法升级"; exit 1; }

# ---- 取发布目录（离线目录 or 下载 Release）----
if [ $# -ge 1 ] && [ -d "$1" ]; then
  SRC="$1"; echo "==> 离线升级：使用本地发布目录 $SRC"
else
  VER="${1:-latest}"
  ARCH=$(uname -m); case "$ARCH" in
    x86_64) TARCH=amd64;; aarch64|arm64) TARCH=arm64;;
    *) echo "不支持的架构: $ARCH（仅支持 amd64/arm64）"; exit 1;;
  esac
  if [ "$VER" = "latest" ]; then
    VER=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | grep -o '"tag_name": *"[^"]*"' | cut -d'"' -f4)
    [ -n "$VER" ] || { echo "获取最新版本失败"; exit 1; }
  fi
  echo "==> fleetboard $VER ($TARCH)"
  TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
  URL="https://github.com/$REPO/releases/download/$VER/fleetboard-$VER-linux-$TARCH.tar.gz"
  echo "==> 下载 $URL"
  curl -fSL --progress-bar -o "$TMP/pkg.tar.gz" "$URL"
  SUMS=$(curl -fsSL "https://github.com/$REPO/releases/download/$VER/sums.txt" 2>/dev/null || true)
  if [ -n "$SUMS" ]; then
    echo "$SUMS" | grep "linux-$TARCH.tar.gz" | sed "s|fleetboard-$VER-linux-$TARCH.tar.gz|$TMP/pkg.tar.gz|" | sha256sum -c - \
      && echo "==> 校验通过" || { echo "❌ 校验和不匹配，中止"; exit 1; }
  else
    echo "⚠️ 未找到 sums.txt，跳过校验"
  fi
  tar xzf "$TMP/pkg.tar.gz" -C "$TMP"
  SRC="$TMP/fleetboard-$VER"
fi

[ -x "$SRC/fleetboard" ] || { echo "发布目录缺二进制 fleetboard"; exit 1; }
[ -f "$SRC/web-dist/index.html" ] || { echo "发布目录缺 web-dist/"; exit 1; }

# 架构校验（同 install.sh：读 ELF 头 e_machine，62=amd64 183=arm64）
host_arch=$(uname -m); case "$host_arch" in x86_64) want=62;; aarch64|arm64) want=183;; *) want=0;; esac
elf_machine=$(od -An -j18 -N2 -tu2 "$SRC/fleetboard" | tr -d ' ')
[ "$elf_machine" = "$want" ] || { echo "二进制架构(e_machine=$elf_machine)与本机($host_arch)不符"; exit 1; }

PORT_NUM=$(grep -E '^PORT=' "$BASE/.env" | cut -d= -f2); PORT_NUM=${PORT_NUM:-8080}
health() { curl -fsS "http://127.0.0.1:$PORT_NUM/api/health" 2>/dev/null; }

was_active=0
if systemctl is-active --quiet fleetboard 2>/dev/null; then was_active=1; fi

echo "==> 停止服务"
systemctl stop fleetboard 2>/dev/null || true

echo "==> 备份数据库"
BK="$DATA/backup"; mkdir -p "$BK"
DB="$DATA/fleetboard.db"
if [ -f "$DB" ]; then
  BKFILE="$BK/fleetboard-$(date +%F-%H%M).db"
  if command -v sqlite3 >/dev/null 2>&1; then
    sqlite3 "$DB" "VACUUM INTO '$BKFILE'"
    echo "  VACUUM INTO → $BKFILE"
  else
    cp "$DB" "$BKFILE"
    if [ -f "$DB-wal" ]; then cp "$DB-wal" "$BKFILE-wal"; fi
    if [ -f "$DB-shm" ]; then cp "$DB-shm" "$BKFILE-shm"; fi
    echo "  已拷贝（含 WAL/SHM）→ $BKFILE"
  fi
  ls -1t "$BK"/fleetboard-*.db 2>/dev/null | tail -n +6 | xargs -r rm -f  # 只留最近 5 份
fi

echo "==> 替换二进制与前端（.env 与数据库不动）"
rm -f "$BASE/fleetboard.prev"
mv "$BASE/fleetboard" "$BASE/fleetboard.prev"
install -m 755 "$SRC/fleetboard" "$BASE/fleetboard"
rm -rf "$BASE/web-dist"
cp -r "$SRC/web-dist" "$BASE/web-dist"
if [ -f "$SRC/uninstall.sh" ]; then install -m 755 "$SRC/uninstall.sh" "$BASE/uninstall.sh"; fi

rollback() {
  echo "❌ 升级失败，回滚到旧版本" >&2
  systemctl stop fleetboard 2>/dev/null || true
  mv "$BASE/fleetboard.prev" "$BASE/fleetboard"
  if [ "$was_active" = 1 ]; then systemctl start fleetboard 2>/dev/null || true; fi
  echo "   已恢复旧二进制，请排查：journalctl -u fleetboard -n 50" >&2
  exit 1
}

echo "==> 启动服务"
systemctl start fleetboard
ok=""
for _ in $(seq 1 15); do
  if health; then ok=1; echo; break; fi
  sleep 1
done
[ -n "$ok" ] || { echo "health 检查未通过" >&2; rollback; }

echo "==> 升级完成：$(health | grep -o '"version":"[^"]*"' || echo "版本号未知")"
echo "    旧版本留作 $BASE/fleetboard.prev（回滚：停服后 mv 回并 systemctl start fleetboard）"
echo "    .env 与数据库未改动；数据库快照在 $BK/"
