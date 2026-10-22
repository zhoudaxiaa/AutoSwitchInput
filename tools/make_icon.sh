#!/bin/bash
# 生成图标资源：AppIcon.icns + 菜单栏 template 图标
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "==> 编译图标生成器"
mkdir -p build
swiftc -O tools/make_icon.swift -o build/make_icon

echo "==> 渲染"
./build/make_icon build

echo "==> 打包 iconset"
ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z "$s" "$s" build/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z "$((s * 2))" "$((s * 2))" build/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o Resources/AppIcon.icns

cp build/MenuBarIcon.png Resources/MenuBarIcon.png
cp "build/MenuBarIcon@2x.png" "Resources/MenuBarIcon@2x.png"

echo "==> 完成"
ls -la Resources/AppIcon.icns Resources/MenuBarIcon*.png
