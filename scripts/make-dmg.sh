#!/bin/bash
# 배포용 DMG 를 만든다.
#
#   ./scripts/make-dmg.sh
#
# Apple Silicon 과 Intel 양쪽에서 도는 universal 앱을 담는다.
# Developer ID 인증서와 공증 프로필(notarytool 키체인 프로필 "aibar")이 있으면
# 서명과 공증까지 하고, 없으면 ad-hoc 상태로 만든다.
# 결과물: build/AIBar-<버전>.dmg
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
APP="$ROOT/build/AIBar.app"
STAGING="$ROOT/build/dmg"

"$ROOT/scripts/build-app.sh" --universal

VERSION="$(git -C "$ROOT" describe --tags --always 2>/dev/null || echo "0.1.0")"
DMG="$ROOT/build/AIBar-$VERSION.dmg"

echo "==> DMG 내용 구성"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/AIBar.app"
# 끌어다 놓을 자리를 만들어 준다.
ln -s /Applications "$STAGING/Applications"

echo "==> DMG 생성"
hdiutil create \
    -volname "AIBar" \
    -srcfolder "$STAGING" \
    -ov -format UDZO \
    "$DMG" >/dev/null

rm -rf "$STAGING"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/' || true)"

if [ -z "$IDENTITY" ]; then
    echo "==> Developer ID 인증서가 없어 서명·공증을 건너뜀"
    echo "    받는 쪽에서 Gatekeeper 경고를 한 번 넘겨야 합니다. README 의 설치 방법을 함께 안내하세요."
    echo
    echo "완료: $DMG"
    du -h "$DMG" | sed 's/^/    /'
    exit 0
fi

echo "==> DMG 서명: $IDENTITY"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

# 공증 프로필이 등록돼 있으면 공증까지 한다.
# 등록: xcrun notarytool store-credentials aibar --apple-id <ID> --team-id <TEAM> --password <앱암호>
if xcrun notarytool history --keychain-profile aibar >/dev/null 2>&1; then
    echo "==> 공증 요청"
    xcrun notarytool submit "$DMG" --keychain-profile aibar --wait
    echo "==> 공증 결과 첨부"
    xcrun stapler staple "$DMG"
else
    echo "==> 공증 건너뜀 (notarytool 프로필 'aibar' 없음)"
    echo "    받는 쪽에서 Gatekeeper 경고를 한 번 넘겨야 합니다. README 의 설치 방법을 함께 안내하세요."
fi

echo
echo "완료: $DMG"
du -h "$DMG" | sed 's/^/    /'
