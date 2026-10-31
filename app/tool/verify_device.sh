#!/usr/bin/env bash
# 真机验证：一键走「首页 → 历史 → 详情」，只截屏、不改任何数据。
#
# 为什么要有这个脚本：手机在用户手里，能用的窗口很短。手敲一串 adb 命令
# 既慢又容易在两条命令之间把前台搞丢（已经抢屏三次）。这里把整个流程
# 串起来，每一步都过 `safe_adb.sh` 的前台守卫，一旦前台不是本 App 立即退出。
#
# 用法：
#   bash tool/verify_device.sh           # 从桌面启动并走完三步
#   bash tool/verify_device.sh --shots   # 只截当前屏幕
#
# 产物：.workbuddy/shots/verify/{01-首页,02-历史,03-详情}.png
set -u

cd "$(dirname "$0")/.." || exit 1
ADB="${ADB:-D:/Android/Sdk/platform-tools/adb.exe}"
OUT=".workbuddy/shots/verify"
SAFE="bash tool/safe_adb.sh"

mkdir -p "$OUT"
stamp() { date +%H%M%S; }

shot() {
  local name="$1"
  "$ADB" exec-out screencap -p > "$OUT/$name.png" 2>/dev/null
  local bytes; bytes=$(stat -c%s "$OUT/$name.png" 2>/dev/null || echo 0)
  if [ "$bytes" -lt 10000 ]; then
    # 锁屏状态下 screencap 会被拦，拉回来是 0 字节 —— 别当成「截到了」。
    echo "!! $name 截图异常（${bytes}B），手机可能锁屏" >&2
    return 1
  fi
  echo "   $name.png  ${bytes}B  $(stamp)"
}

w() { sleep "$1"; }

mode="${1:-}"

if [ "$mode" = "--shots" ]; then
  shot "01-当前"
  exit $?
fi

# 1. 启动（只允许从桌面或本 App 内启动）
echo "[1/3] 启动 App"
$SAFE launch || { echo "退出：手机不在可用状态（见上面的原因）" >&2; exit 3; }
w 2.5
shot "01-首页" || exit 4

# 2. 底部中间那个 Tab = 历史。坐标按 1080×2340 量：x 居中，y 在 95% 高处。
#    这里不硬编码像素，用屏幕尺寸算 —— 换机器也能用。
size=$("$ADB" shell wm size | tr -d '\r' | grep -o '[0-9]*x[0-9]*' | head -1)
W=${size%x*}; H=${size#*x}
TX=$((W / 2)); TY=$((H * 95 / 100))
echo "[2/3] 点历史 Tab ($TX, $TY)"
$SAFE tap "$TX" "$TY" || exit 3
w 1.8
shot "02-历史" || exit 4

# 3. 点第一条记录（列表从卡片区顶部开始，约 22% 高处）
LX=$((W / 2)); LY=$((H * 22 / 100))
echo "[3/3] 点第一条记录 ($LX, $LY)"
$SAFE tap "$LX" "$LY" || exit 3
w 1.8
shot "03-详情" || exit 4

echo
echo "完成：$OUT/01-首页.png 02-历史.png 03-详情.png"
echo "重点看：历史卡片的时间是「10-20 15:48」这种，还是「今天」"
