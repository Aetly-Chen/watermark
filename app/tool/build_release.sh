#!/usr/bin/env bash
# Release 包构建脚本 —— 必须跑这一步，不能直接 `flutter build apk --release`。
#
# 原因（2026-10-17 实测，别再重新踩）：
#   工程在 `D:\项目\watermark`，路径含中文。debug 构建正常，但 **release 走 AOT**，
#   gen_snapshot 是原生程序、按系统 ANSI 代码页读路径，中文变成 `???`：
#
#     Error: Unable to read file: D:\???\watermark\app\.dart_tool\flutter_build\<hash>\app.dill
#     Dart snapshot generator failed with exit code 255
#     Target android_aot_release_android-arm64 failed
#
#   把同一份源码搬到纯 ASCII 路径（默认 D:\dev\wm_app）再 build，一次过（118.7 MB）。
#
# 用法：
#   bash tool/build_release.sh            # arm64，产物拷到 D:\dev\apk\
#   bash tool/build_release.sh android-arm64 android-arm
#
# 注意：这里复制的是**源码快照**，不是符号链接 —— 每次构建都重新拷一遍，
# 复制完的目录用完即删，避免出现「两份源码各自演化」的情况。

set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE="${STAGE_DIR:-/d/dev/wm_app}"
OUT_DIR="${OUT_DIR:-/d/dev/apk}"
TARGETS=("android-arm64")
if [[ $# -gt 0 ]]; then TARGETS=("$@"); fi

FLUTTER="${FLUTTER:-/d/flutter/bin/flutter.bat}"
# localhost 必须绕过代理，否则 pub / 工具有时会去连代理（见 README 第四节）
export NO_PROXY="127.0.0.1,localhost${NO_PROXY:+,$NO_PROXY}"
export no_proxy="$NO_PROXY"

echo "==> 源码: $APP_DIR"
echo "==> 暂存: $STAGE"
echo "==> 产物: $OUT_DIR"
echo "==> ABI : ${TARGETS[*]}"

# 暂存目录删不掉要立刻停 —— 第二次跑脚本时最常出这个，
# 批量删除会被安全策略拦（一次 3800+ 个文件），停在「删除」这一步比编到一半崩好查。
if ! rm -rf "$STAGE" 2>/dev/null; then
  echo "!! 暂存目录删不掉：$STAGE（批量删除被拦了）" >&2
  echo "   手动清：powershell -c \"[IO.Directory]::Delete('$(cygpath -w "$STAGE" 2>/dev/null || echo "$STAGE")',\$true)\"" >&2
  exit 1
fi
mkdir -p "$STAGE" "$OUT_DIR"

# 只带源码与构建配置，不带 build/ 和 .dart_tool/（会重新生成）
for item in lib android assets test integration_test tool; do
  [[ -e "$APP_DIR/$item" ]] && cp -r "$APP_DIR/$item" "$STAGE/"
done
for item in pubspec.yaml pubspec.lock analysis_options.yaml; do
  [[ -e "$APP_DIR/$item" ]] && cp "$APP_DIR/$item" "$STAGE/"
done

cd "$STAGE"
"$FLUTTER" pub get

ABI_FLAGS=()
for t in "${TARGETS[@]}"; do ABI_FLAGS+=(--target-platform "$t"); done

# 可选：透传一个 dart-define，例如
#   WM_DART_DEFINE=WM_FRAME_PROBE=true bash tool/build_release.sh
# 用来在 AOT 包里量帧耗时（探针默认关闭，不加这个参数就不打日志）。
DEFINE_FLAGS=()
if [[ -n "${WM_DART_DEFINE:-}" ]]; then DEFINE_FLAGS+=(--dart-define "$WM_DART_DEFINE"); fi

"$FLUTTER" build apk --release "${ABI_FLAGS[@]}" "${DEFINE_FLAGS[@]}"

APK="$STAGE/build/app/outputs/flutter-apk/app-release.apk"
if [[ ! -f "$APK" ]]; then
  echo "!! 没找到产物: $APK" >&2
  exit 1
fi

DEST="$OUT_DIR/watermark-remover-release.apk"
cp "$APK" "$DEST"
echo
echo "==> 完成: $DEST"
ls -lh "$DEST"

# 装到真机要相对路径（adb.exe 读不了中文绝对路径）；这里目录是 ASCII，直接用绝对路径没问题
echo "    adb install -r \"$DEST\""

# 清理不参与退出码：某些受限环境会对批量删除拦截（一次删几千个文件），
# 那种情况下留个明确提示，别把「构建成功」误报成失败。
if rm -rf "$STAGE" 2>/dev/null; then
  echo "==> 已清理暂存目录"
else
  echo "!! 暂存目录没删掉（可能被安全策略拦了），手动删一下: $STAGE"
fi
exit 0
