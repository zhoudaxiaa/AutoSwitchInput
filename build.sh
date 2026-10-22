#!/bin/bash
# 构建 AutoSwitchInput.app
#
#   ./build.sh            通用二进制（arm64 + x86_64）
#   ./build.sh --native   只编译当前架构，速度更快
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT/dist/AutoSwitchInput.app"
MIN_MACOS="13.0"
SRCS=("$ROOT/src/Loc.swift" "$ROOT/src/main.swift")

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
    if compile_slice arm64 "$TMP/arm64" 2>/dev/null && compile_slice x86_64 "$TMP/x86_64" 2>/dev/null; then
        lipo -create "$TMP/arm64" "$TMP/x86_64" -output "$BIN"
        echo "    通用二进制: $(lipo -archs "$BIN")"
    else
        echo "    交叉编译失败，回退到本机架构"
        compile_slice "$(uname -m)" "$BIN"
    fi
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

echo "==> 临时签名"
codesign --force --sign - --identifier com.local.autoswitchinput "$APP"
codesign --verify "$APP" && echo "签名校验通过"

echo "==> 完成: $APP"
