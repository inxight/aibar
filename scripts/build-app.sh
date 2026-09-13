#!/bin/bash
# AIBar.app 번들을 만든다.
#
#   ./scripts/build-app.sh              # 이 기계용 (개발 중)
#   ./scripts/build-app.sh --universal  # 배포용 (Apple Silicon + Intel)
#
# 메뉴바 앱은 번들이 있어야 Dock 숨김(LSUIElement)과 로그인 항목 등록이 제대로 동작한다.
# 결과물: build/AIBar.app
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/AIBar.app"
UNIVERSAL=0

for arg in "$@"; do
    case "$arg" in
        --universal) UNIVERSAL=1 ;;
        *) echo "모르는 옵션: $arg" >&2; exit 1 ;;
    esac
done

if [ ! -f "$ROOT/Resources/AppIcon.icns" ]; then
    echo "==> 앱 아이콘 생성"
    swift "$ROOT/scripts/make-icon.swift"
fi

if [ "$UNIVERSAL" = "1" ]; then
    echo "==> 빌드 (release, arm64 + x86_64)"
    swift build -c release --arch arm64 --arch x86_64
    BINARY="$ROOT/.build/apple/Products/Release/AIBar"
else
    echo "==> 빌드 (release)"
    swift build -c release
    BINARY="$(swift build -c release --show-bin-path)/AIBar"
fi

if [ ! -x "$BINARY" ]; then
    echo "실행 파일을 찾지 못했습니다: $BINARY" >&2
    exit 1
fi

echo "==> 번들 구성"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/AIBar"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

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

# Developer ID 인증서가 있으면 그걸로 서명한다. 없으면 ad-hoc 으로 서명하는데,
# 그 경우 받는 쪽에서 Gatekeeper 경고를 한 번 넘겨야 한다 (README 참고).
# 인증서가 없으면 grep 이 1 로 끝나는데, pipefail 때문에 스크립트가 거기서 죽는다. 막아 둔다.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -n "$IDENTITY" ]; then
    echo "==> 서명: $IDENTITY"
    codesign --force --deep --options runtime --timestamp \
        --sign "$IDENTITY" "$APP"
else
    echo "==> 서명: ad-hoc (Developer ID 인증서 없음)"
    codesign --force --deep --sign - "$APP"
fi

codesign --verify --verbose "$APP" 2>&1 | sed 's/^/    /'

echo "완료: $APP"
if [ "$UNIVERSAL" = "1" ]; then
    lipo -info "$APP/Contents/MacOS/AIBar" | sed 's/^/    /'
fi
