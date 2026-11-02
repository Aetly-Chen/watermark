#!/usr/bin/env bash
# safe_adb.sh —— 真机操作守卫：查前台 → 判断 → 执行 → 回读前台，全在一次调用里。
#
# 用法：
#   bash tools/safe_adb.sh fg                      # 只读：打印当前前台
#   bash tools/safe_adb.sh launch                  # 仅在 launcher 前台时启动本 App
#   bash tools/safe_adb.sh force_start             # force-stop + HOME + 从桌面启动（干净重启）
#   bash tools/safe_adb.sh tap X Y                 # 仅当前台是本 App 时才点
#   bash tools/safe_adb.sh key 4                   # keyevent（注意是 keyevent 不是 key）
#   bash tools/safe_adb.sh ro -- <adb 参数...>     # 只读透传（screencap / logcat / dumpsys ...）
#
# 退出码：0 成功；3 前台不是本 App，没动手机；4 启动前置条件不满足。

set -u

ADB="${ADB:-/d/Android/Sdk/platform-tools/adb.exe}"
PKG="${PKG:-cn.shuiyin.watermark_remover}"
ACT="${ACT:-.MainActivity}"

fg() {
  "$ADB" shell "dumpsys activity activities | grep mResumedActivity" 2>/dev/null \
    | tr -d '\r' | head -1
}

is_self() { fg | grep -q "$PKG"; }
is_home() { fg | grep -qiE 'launcher|unihome'; }

cmd="${1:-fg}"
shift || true

case "$cmd" in
  fg)
    fg
    ;;

  launch)
    if is_self; then
      echo "[launch] 已经是本 App 在前台，直接拉起" >&2
      "$ADB" shell am start -n "$PKG/$ACT" >/dev/null 2>&1
    elif is_home; then
      echo "[launch] 前台是桌面，启动" >&2
      "$ADB" shell am start -n "$PKG/$ACT" >/dev/null 2>&1
    else
      echo "[launch] 拒绝：前台不是桌面也不是本 App —— $(fg)" >&2
      exit 4
    fi
    sleep 2
    fg
    ;;

  force_start)
    # 干净的冷启动：杀进程 → HOME → 从桌面启动，全程不落在别人 App 上
    "$ADB" shell am force-stop "$PKG" >/dev/null 2>&1
    "$ADB" shell input keyevent 3 >/dev/null 2>&1
    sleep 1
    "$ADB" shell am start -n "$PKG/$ACT" >/dev/null 2>&1
    sleep 3
    fg
    ;;

  tap)
    if ! is_self; then
      echo "[tap] 拒绝：前台不是本 App —— $(fg)" >&2
      exit 3
    fi
    "$ADB" shell input tap "$1" "$2" >/dev/null 2>&1
    ;;

  swipe)
    if ! is_self; then
      echo "[swipe] 拒绝：前台不是本 App —— $(fg)" >&2
      exit 3
    fi
    "$ADB" shell input swipe "$@" >/dev/null 2>&1
    ;;

  key)
    # 只放行不会误伤别人的键：BACK(4) / HOME(3)
    if ! is_self; then
      echo "[key] 拒绝：前台不是本 App —— $(fg)" >&2
      exit 3
    fi
    "$ADB" shell input keyevent "$@" >/dev/null 2>&1
    ;;

  ro)
    # 只读透传
    [ "${1:-}" = "--" ] && shift
    "$ADB" "$@"
    ;;

  *)
    echo "未知命令: $cmd" >&2
    exit 2
    ;;
esac
