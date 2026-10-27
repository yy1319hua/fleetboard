#!/usr/bin/env bash
# fleetboard 卸载脚本（root 运行）——装了什么删什么，无残留
# 数据目录删除前需确认；其余为固定布局，直接回收。
set -euo pipefail

BASE=/opt/fleetboard
DATA=/var/lib/fleetboard
UNIT=/etc/systemd/system/fleetboard.service

[ "$(id -u)" = 0 ] || { echo "请用 root 运行"; exit 1; }

echo "==> 停止并移除 systemd 服务"
systemctl disable --now fleetboard 2>/dev/null || true
rm -f "$UNIT"
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "==> 回收程序目录 $BASE"
rm -rf "$BASE"

echo "==> 回收用户"
id fleetboard >/dev/null 2>&1 && userdel fleetboard || true

if [ -d "$DATA" ]; then
  echo
  echo "发现数据目录 $DATA（SQLite 数据库，含纳管记录与凭据密文）"
  read -rp "确认删除？输入 DELETE 继续，其他任意键保留: " a
  [ "$a" = "DELETE" ] && { rm -rf "$DATA"; echo "已删除 $DATA"; } || echo "已保留 $DATA"
fi

echo "==> 残留扫描"
found=0
for p in "$UNIT" "$BASE" /etc/systemd/system/fleetboard.service.d; do
  if [ -e "$p" ]; then echo "  残留: $p（未删，请手动确认）"; found=1; fi
done
ls /tmp | grep -i fleetboard 2>/dev/null | sed 's/^/  \/tmp\/残留: /' && found=1 || true
[ $found = 0 ] && echo "  ✅ 无残留，卸载完成" || echo "  ⚠️ 存在上述残留项"
