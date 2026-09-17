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

echo "빌드 중 (release)..."
swift build -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/PaneDock" "$APP/Contents/MacOS/PaneDock"

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
	<key>CFBundleIdentifier</key>
	<string>dev.panedock.prototype</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.1a</string>
	<key>CFBundleVersion</key>
	<string>1</string>
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
