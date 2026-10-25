#!/bin/bash
# 构建 AutoSwitchInput.app
#
#   ./build.sh            通用二进制（arm64 + x86_64）
#   ./build.sh --native   只编译当前架构，速度更快
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/AutoSwitchInput.app"
MIN_MACOS="13.0"

# 递归收集 src/ 下所有 .swift（分层目录，新增文件不用改这里）
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$ROOT/src" -name '*.swift' | sort)

UNIVERSAL=1
[ "${1:-}" = "--native" ] && UNIVERSAL=0

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile_slice() {
    local arch="$1" out="$2"
    swiftc -O -whole-module-optimization \
        -target "${arch}-apple-macosx${MIN_MACOS}" \
        "${SRCS[@]}" \
        -o "$out"
}

echo "==> 编译"
BIN="$APP/Contents/MacOS/AutoSwitchInput"
if [ "$UNIVERSAL" = "1" ]; then
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    compile_slice arm64 "$TMP/arm64"
    compile_slice x86_64 "$TMP/x86_64"
    lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
    echo "    通用二进制: $(lipo -archs "$BIN")"
else
    compile_slice "$(uname -m)" "$BIN"
fi

echo "==> 资源"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
for f in MenuBarIcon.png "MenuBarIcon@2x.png"; do
    [ -f "$ROOT/Resources/$f" ] && cp "$ROOT/Resources/$f" "$APP/Contents/Resources/$f"
done
for lang in en zh-Hans; do
    mkdir -p "$APP/Contents/Resources/$lang.lproj"
    cp "$ROOT/Resources/$lang.lproj/"*.strings "$APP/Contents/Resources/$lang.lproj/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> 签名"
# 优先用本机自签名证书：ad-hoc 签名每次编译 cdhash 都会变，
# macOS 会把「辅助功能」授权判为失效，用户得反复重新勾选。
SIGN_ID="${SIGN_IDENTITY:-AutoSwitchInput Local}"
if codesign --force --sign "$SIGN_ID" --identifier com.local.autoswitchinput "$APP" 2>/dev/null; then
    echo "    证书: $SIGN_ID"
else
    codesign --force --sign - --identifier com.local.autoswitchinput "$APP"
    echo "    警告：使用 ad-hoc 临时签名（未找到 $SIGN_ID）。更新已安装版本后，辅助功能授权可能失效。" >&2
    echo "    如位置识别不可用：在系统设置 → 辅助功能中关闭再开启本应用，必要时移除旧条目并重新添加。" >&2
fi
codesign --verify "$APP" && echo "签名校验通过"

echo "==> 完成: $APP"
