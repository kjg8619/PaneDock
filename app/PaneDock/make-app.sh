#!/bin/bash
# PaneDock 최소 .app 번들 생성.
#
# Xcode 없이 Command Line Tools만으로 만든다. 의존성 설치 없음.
# 서명은 ad-hoc(`-`)이며 Developer ID 서명·공증은 하지 않는다.
#
# 사용법: bash make-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP="dist/PaneDock.app"
BIN_PATH="$(swift build -c release --show-bin-path)"

# 실행본 식별: 제품 버전은 소스 한 곳에서 읽고, 빌드 번호·SHA·작업 트리 상태는 git에서 얻는다.
VERSION_SOURCE="../../prototypes/focus-probe/Sources/FocusProbeCore/BuildIdentity.swift"
PRODUCT_VERSION="$(sed -n 's/.*static let productVersion = "\([^"]*\)".*/\1/p' "$VERSION_SOURCE" | head -1)"
[ -n "$PRODUCT_VERSION" ] || PRODUCT_VERSION="0.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 0)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)"
if [ -n "$(git status --porcelain 2>/dev/null)" ]; then GIT_DIRTY="1"; else GIT_DIRTY="0"; fi
echo "식별: version=$PRODUCT_VERSION build=$BUILD_NUMBER sha=$GIT_SHA dirty=$GIT_DIRTY"

echo "빌드 중 (release)..."
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/PaneDock" "$APP/Contents/MacOS/PaneDock"
# A 시안의 앱 아이콘(제작용 에셋)을 번들에 넣는다. 생성: assets/make-icon.swift 참고.
if [ -f assets/PaneDock.icns ]; then
    cp assets/PaneDock.icns "$APP/Contents/Resources/PaneDock.icns"
else
    echo "경고: assets/PaneDock.icns 없음 — 아이콘 없이 만든다"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>PaneDock</string>
	<key>CFBundleDisplayName</key>
	<string>PaneDock</string>
	<key>CFBundleExecutable</key>
	<string>PaneDock</string>
	<key>CFBundleIconFile</key>
	<string>PaneDock</string>
	<key>CFBundleIdentifier</key>
	<string>dev.panedock.prototype</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>__PRODUCT_VERSION__</string>
	<key>CFBundleVersion</key>
	<string>__BUILD_NUMBER__</string>
	<!-- 실행 중인 빌드를 진단 화면에서 확인할 수 있게 한다. 수정된 작업 트리로 만든 빌드는 dirty=1이다. -->
	<key>PaneDockGitSHA</key>
	<string>__GIT_SHA__</string>
	<key>PaneDockGitDirty</key>
	<string>__GIT_DIRTY__</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<!-- Dock 아이콘 없이 메뉴 막대에만 나타난다. 기존 Dock 설정은 건드리지 않는다. -->
	<key>LSUIElement</key>
	<true/>
	<!-- 자동화 승인 대화상자에 표시될 사용 목적. -->
	<key>NSAppleEventsUsageDescription</key>
	<string>Ghostty에서 현재 포커스된 pane의 작업 경로를 읽기 위해서만 사용합니다. 터미널에 입력을 보내거나 화면 내용을 읽지 않습니다.</string>
</dict>
</plist>
PLIST

# 자리표시자를 실제 식별자로 바꾼다.
sed -i '' -e "s/__PRODUCT_VERSION__/$PRODUCT_VERSION/" \
          -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/" \
          -e "s/__GIT_SHA__/$GIT_SHA/" \
          -e "s/__GIT_DIRTY__/$GIT_DIRTY/" "$APP/Contents/Info.plist"

# ad-hoc 서명. TCC가 번들 단위로 권한을 기억할 수 있게 한다.
if codesign --force --sign - "$APP" 2>/dev/null; then
    echo "ad-hoc 서명 완료"
else
    echo "경고: ad-hoc 서명 실패 (실행은 가능)"
fi

echo "생성됨: $APP"
echo "실행:    open \"$APP\"                              # 자동(최전면 앱을 따라간다)"
echo "        open \"$APP\" --args --adapter cmux        # cmux만"
echo "        open \"$APP\" --args --adapter ghostty     # Ghostty만"
echo "        open \"$APP\" --args --fake steady         # 가짜 데이터 모드"
echo "종료:    메뉴 막대 PaneDock > PaneDock 종료  (또는 ⌘Q)"
