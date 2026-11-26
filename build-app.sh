#!/bin/zsh
# 릴리스로 빌드한 실행 파일을 더블클릭으로 여는 DiskVitals.app 묶음과 배포용 DiskVitals.dmg로 만드는 스크립트
set -euo pipefail
cd "$(dirname "$0")"

# Apple Silicon과 Intel Mac 모두에서 돌아가는 유니버설 실행 파일
ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/DiskVitals"
APP="build/DiskVitals.app"

rm -rf "$APP" DiskVitals.app
mkdir -p build bin
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/DiskVitals"

# 아이콘: 1024px PNG에서 여러 크기를 만들어 .icns로 묶는다
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DiskVitals</string>
    <key>CFBundleDisplayName</key><string>DiskVitals</string>
    <key>CFBundleIdentifier</key><string>local.diskvitals.app</string>
    <key>CFBundleExecutable</key><string>DiskVitals</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" >/dev/null 2>&1 || true
cp "$BIN" bin/DiskVitals

# 폴더 맨 위에 바로 더블클릭할 수 있는 앱을 둔다
rm -rf DiskVitals.app
ditto "$APP" DiskVitals.app

# 다른 Mac에 옮기기 위한 디스크 이미지(앱 + 응용 프로그램 폴더 바로가기)
STAGE="build/dmg"
rm -rf "$STAGE" DiskVitals.dmg
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/DiskVitals.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "DiskVitals" -srcfolder "$STAGE" -ov -format UDZO DiskVitals.dmg >/dev/null
rm -rf "$STAGE"

echo "Built $PWD/DiskVitals.app and $PWD/DiskVitals.dmg"
