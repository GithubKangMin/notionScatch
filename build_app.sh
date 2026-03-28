#!/bin/bash
set -e

APP_NAME="notionScatch"
APP_DIR="$HOME/Desktop/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Building ${APP_NAME}..."
swift build -c release --arch arm64 2>&1

EXEC_PATH=".build/release/${APP_NAME}"
if [ ! -f "$EXEC_PATH" ]; then
    echo "Error: Build failed - executable not found at $EXEC_PATH"
    exit 1
fi

# Remove old app if exists
rm -rf "$APP_DIR"

# Create .app bundle structure
mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"

# Copy executable
cp "$EXEC_PATH" "$MACOS_DIR/${APP_NAME}"

# Create Info.plist
cat > "${CONTENTS_DIR}/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>com.kmg.${APP_NAME}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Notion Scatch</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Finder Quick Look을 열어 iPad에서 이미지를 편집하기 위해 필요합니다.</string>
</dict>
</plist>
PLIST

# Ad-hoc code signing (권한 재설정 없이 빌드 가능)
codesign --force --sign - "${APP_DIR}" 2>&1

echo ""
echo "✅ ${APP_NAME}.app 생성 완료! (코드사이닝 완료)"
echo "   위치: ${APP_DIR}"
echo "   더블클릭으로 실행하세요."
