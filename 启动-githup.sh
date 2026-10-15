#!/usr/bin/env bash
# ============================================================
#  githup 桌面版 —— macOS / Linux 启动脚本
#  双击或终端执行 ./启动-githup.sh
#  需要 Node.js 18 或更高版本
# ============================================================
cd "$(dirname "$0")" || exit 1

if ! command -v node >/dev/null 2>&1; then
  echo ""
  echo "  没检测到 Node.js。"
  echo "  请先安装 Node.js 18+（https://nodejs.org），然后重新运行本脚本。"
  echo ""
  exit 1
fi

exec node server.js
