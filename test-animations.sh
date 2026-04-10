#!/usr/bin/env bash
# test-animations.sh — 逐个加载所有 SVG 动画，目视检查渲染质量
#
# 通过 POST /debug/svg 直接加载 SVG 文件，同时冻结状态机输出，
# 避免睡眠定时器/idle 动画覆盖测试画面。退出时自动解冻恢复。
#
# 用法:
#   ./test-animations.sh              # 每个动画停留 3 秒，自动轮播
#   ./test-animations.sh 5            # 每个动画停留 5 秒
#   ./test-animations.sh interactive  # 交互模式，按回车切下一个
#   ./test-animations.sh notification # 只看某个 SVG

set -euo pipefail

PORT="${CLAWD_PORT:-23333}"
BASE="http://127.0.0.1:${PORT}"

SVGS=(
  # --- 普通状态 ---
  "clawd-idle-follow.svg"
  "clawd-idle-living.svg"
  "clawd-idle-look.svg"
  "clawd-idle-reading.svg"
  "clawd-idle-music.svg"
  # --- 工作状态 ---
  "clawd-working-thinking.svg"
  "clawd-working-typing.svg"
  "clawd-working-building.svg"
  "clawd-working-builder.svg"
  "clawd-working-juggling.svg"
  "clawd-working-carrying.svg"
  "clawd-working-sweeping.svg"
  "clawd-working-conducting.svg"
  "clawd-working-pushing.svg"
  "clawd-working-debugger.svg"
  "clawd-working-confused.svg"
  "clawd-working-overheated.svg"
  "clawd-working-wizard.svg"
  "clawd-working-beacon.svg"
  "clawd-working-success.svg"
  "clawd-working-ultrathink.svg"
  # --- 反应 ---
  "clawd-happy.svg"
  "clawd-notification.svg"
  "clawd-error.svg"
  "clawd-dizzy.svg"
  "clawd-react-left.svg"
  "clawd-react-right.svg"
  "clawd-react-double.svg"
  "clawd-react-double-jump.svg"
  "clawd-react-annoyed.svg"
  "clawd-react-salute.svg"
  "clawd-react-drag.svg"
  # --- 睡眠序列 ---
  "clawd-idle-yawn.svg"
  "clawd-idle-doze.svg"
  "clawd-idle-collapse.svg"
  "clawd-collapse-sleep.svg"
  "clawd-sleeping.svg"
  "clawd-wake.svg"
  # --- Mini 模式 ---
  "clawd-mini-idle.svg"
  "clawd-mini-enter.svg"
  "clawd-mini-peek.svg"
  "clawd-mini-peek-up.svg"
  "clawd-mini-alert.svg"
  "clawd-mini-happy.svg"
  "clawd-mini-crabwalk.svg"
  "clawd-mini-enter-sleep.svg"
  "clawd-mini-sleep.svg"
  # --- 其他 ---
  "clawd-crab-walking.svg"
  "clawd-going-away.svg"
  "clawd-disconnected.svg"
  "clawd-static-base.svg"
)

load_svg() {
  curl -s --max-time 2 -X POST "${BASE}/debug/svg" \
    -H "Content-Type: application/json" \
    -d "{\"svg\": \"$1\"}" > /dev/null 2>&1 || true
}

debug_reset() {
  curl -s --max-time 2 -X POST "${BASE}/debug/reset" > /dev/null 2>&1 || true
}

cleanup() {
  trap - INT TERM
  echo ""
  echo "🔄 解冻状态机，恢复正常..."
  debug_reset
  exit 0
}
trap cleanup INT TERM

if ! curl -s --max-time 2 "${BASE}/state" > /dev/null 2>&1; then
  echo "❌ hey-clawd 没在运行，或端口不是 ${PORT}"
  exit 1
fi

echo "🦀 hey-clawd SVG 动画测试 (端口 ${PORT}，共 ${#SVGS[@]} 个)"
echo "   状态机已冻结，不会被睡眠/idle 动画干扰"
echo "   Ctrl+C 退出并解冻恢复"
echo ""

# 单个 SVG 模式
if [[ "${1:-}" != "" && "${1:-}" != "interactive" && ! "${1:-}" =~ ^[0-9]+$ ]]; then
  target="$1"
  [[ "$target" != *.svg ]] && target="${target}.svg"
  [[ "$target" != clawd-* ]] && target="clawd-${target}"
  echo "▶ 单个测试: ${target}"
  load_svg "$target"
  echo "  已加载，按 Ctrl+C 结束"
  read -r || true
  cleanup
fi

DELAY="${1:-3}"
INTERACTIVE=false
if [[ "$DELAY" == "interactive" ]]; then
  INTERACTIVE=true
  DELAY=0
fi

total=${#SVGS[@]}
for i in "${!SVGS[@]}"; do
  svg="${SVGS[$i]}"
  idx=$((i + 1))
  name="${svg#clawd-}"
  name="${name%.svg}"
  echo "[${idx}/${total}] ▶ ${name}"
  load_svg "$svg"

  if $INTERACTIVE; then
    read -r -p "  按回车继续... " || break
  else
    sleep "$DELAY"
  fi
done

echo ""
echo "✅ 全部 ${total} 个 SVG 轮播完成"
debug_reset
echo "🔄 已解冻恢复"
