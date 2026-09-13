#!/bin/bash
# AIBar.app 번들을 만든다.
#
# 메뉴바 앱은 번들이 있어야 Dock 숨김(LSUIElement)과 로그인 항목 등록이 제대로 동작한다.
# 결과물: build/AIBar.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
CONFIG="${1:-release}"
APP="$ROOT/build/AIBar.app"

echo "==> 빌드 ($CONFIG)"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/AIBar"

if [ ! -x "$BINARY" ]; then
    echo "실행 파일을 찾지 못했습니다: $BINARY" >&2
    exit 1
fi

echo "==> 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AIBar"

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AIBar</string>
    <key>CFBundleDisplayName</key>
    <string>AIBar</string>
    <key>CFBundleExecutable</key>
    <string>AIBar</string>
    <key>CFBundleIdentifier</key>
    <string>kr.co.inxight.aibar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <!-- Dock 에 띄우지 않고 메뉴바에만 산다 -->
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

echo "==> 서명 (ad-hoc)"
codesign --force --deep --sign - "$APP"

echo "완료: $APP"
