#!/usr/bin/env bash
# 带前台守卫的 adb 交互命令。
#
# 为什么需要它：`adb shell input tap` 落在**前台那个 App** 上，而两条命令之间前台
# 是会变的（10-22 一次从贴吧跳到「华为清理加速」，又一次变成抖音，两次都直接
# 点进了用户正在用的应用）。手写 `查前台 && 点击` 挡不住，因为守卫和点击之间
# 还有一次 adb 往返。
#
# 这个脚本把「查前台 → 判断 → 执行」放在同一次调用里，参数解析和守卫紧邻，
# 中间不再有可乘之机；并且**每次执行完立刻回读一次前台**，跑到别的 App 上就报警。
#
# 用法：
#   bash tool/safe_adb.sh tap 540 1200
#   bash tool/safe_adb.sh swipe 400 900 400 400 300
#   bash tool/safe_adb.sh key 4                       # BACK
#   bash tool/safe_adb.sh launch                     # 仅从桌面启动本 App
#   bash tool/safe_adb.sh whoami                     # 只查前台，不操作
#
# 退出码：0 执行了 / 3 前台不是本 App（未执行）/ 4 设备不在线
set -u

PKG="cn.shuiyin.watermark_remover"
ADB="${ADB:-D:/Android/Sdk/platform-tools/adb.exe}"

foreground() {
  "$ADB" shell "dumpsys activity activities | grep mResumedActivity" 2>/dev/null \
    | tr -d '\r' | head -1
}

fail_offline() {
  echo "!! 设备不在线：$("$ADB" devices | tr -d '\r' | sed -n '2p')" >&2
  exit 4
}

refuse() {
  echo "!! 拒绝执行：前台是「$1」，不是水印工坊。没动手机。" >&2
  exit 3
}

is_launcher() {
  case "$1" in
    *launcher*|*Launcher*|*unihome*|*UniHome*) return 0 ;;
    *) return 1 ;;
  esac
}

is_our_app() {
  case "$1" in
    *"$PKG"*) return 0 ;;
    *) return 1 ;;
  esac
}

cmd="${1:-}"
[ -z "$cmd" ] && { sed -n '13,30p' "$0"; exit 1; }

"$ADB" devices | grep -q "device$" || fail_offline

fg="$(foreground)"
case "$cmd" in
  whoami)
    echo "$fg"
    ;;
  launch)
    # 只允许从桌面启动：别人正在用的 App 上直接 am start 会把他的屏幕顶掉。
    # 已经在我们的 App 里就什么都不用做。
    if is_our_app "$fg"; then
      echo "already: $fg"
    elif is_launcher "$fg"; then
      "$ADB" shell am start -n "$PKG/.MainActivity" >/dev/null 2>&1
      echo "launched from launcher"
    else
      refuse "$fg"
    fi
    ;;
  tap|swipe)
    if ! is_our_app "$fg"; then refuse "$fg"; fi
    "$ADB" shell input "$@" || { echo "!! adb input 失败：$cmd" >&2; exit 6; }
    # 执行完立刻回读：命令跑出去之后前台若变了，说明这一下可能落到了别处。
    after="$(foreground)"
    if ! is_our_app "$after"; then
      echo "!! 警告：命令执行后前台变成了「$after」，请人工确认刚才那一下落在哪" >&2
      exit 5
    fi
    echo "ok: $cmd @ $after"
    ;;
  key)
    # `input` 的子命令叫 **keyevent**，不是 key。写成 `input key 4` 会得到一句
    # 英文 "Unknown command: key"，而且**退出码仍是 0** —— 看着像执行成功了。
    # 我第一版就是 `input "$@"` 直接透传，结果 BACK 根本没发出去。
    if ! is_our_app "$fg"; then refuse "$fg"; fi
    shift
    [ $# -eq 0 ] && { echo "用法：safe_adb.sh key <code>（4 = BACK）" >&2; exit 1; }
    "$ADB" shell input keyevent "$@" || { echo "!! keyevent 失败" >&2; exit 6; }
    after="$(foreground)"
    echo "ok: keyevent $* @ $after"
    ;;
  back)
    if ! is_our_app "$fg"; then refuse "$fg"; fi
    "$ADB" shell input keyevent 4 || exit 6
    echo "ok: BACK"
    ;;
  *)
    echo "未知命令：$cmd" >&2
    exit 1
    ;;
esac
