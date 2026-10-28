#!/usr/bin/env bash
# fleetboard 远程一条命令安装：
#   curl -fsSL https://raw.githubusercontent.com/yy1319hua/fleetboard/main/deploy/install-remote.sh | sudo bash
# 或固定版本：
#   curl -fsSL .../install-remote.sh | sudo bash -s -- v0.1.0
# 逻辑：探测架构 → 从 GitHub Releases 下载对应发布包 → 校验 → 解包 → 执行包内 install.sh
set -euo pipefail

REPO="yy1319hua/fleetboard"
VER="${1:-latest}"

[ "$(id -u)" = 0 ] || { echo "请用 root 运行（curl ... | sudo bash）"; exit 1; }

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

# 校验和（ Releases 附带 sums.txt，对不上即中止）
SUMS=$(curl -fsSL "https://github.com/$REPO/releases/download/$VER/sums.txt" 2>/dev/null || true)
if [ -n "$SUMS" ]; then
  echo "$SUMS" | grep "linux-$TARCH.tar.gz" | sed "s|fleetboard-$VER-linux-$TARCH.tar.gz|$TMP/pkg.tar.gz|" | sha256sum -c - \
    && echo "==> 校验通过" || { echo "❌ 校验和不匹配，中止"; exit 1; }
else
  echo "⚠️ 未找到 sums.txt，跳过校验"
fi

echo "==> 解包"
tar xzf "$TMP/pkg.tar.gz" -C "$TMP"
cd "$TMP/fleetboard-$VER"

# 已安装机器禁止重跑 install.sh（会刷新 KEY 致凭据全废）→ 改走升级脚本
if [ -f /opt/fleetboard/.env ]; then
  echo "==> 检测到已安装，改走升级流程"
  exec ./upgrade.sh "$VER"
fi
exec ./install.sh
