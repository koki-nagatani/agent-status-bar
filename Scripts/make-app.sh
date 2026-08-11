#!/bin/bash
# SPM でビルドした実行ファイルを macOS の .app バンドルに包む。
#
# メニューバー常駐アプリは bundle が必須である:
#   - LSUIElement で Dock アイコンを消せる
#   - UNUserNotificationCenter が bundle identifier を要求する
# Xcode プロジェクトを持たずに済ませるため、ここで手組みする。
set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/AgentStatusBar.app"
BUNDLE_ID="dev.knagatani.AgentStatusBar"
VERSION="0.1.0"

cd "$ROOT"
echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product AgentStatusBarApp

BIN="$(swift build -c "$CONFIG" --product AgentStatusBarApp --show-bin-path)/AgentStatusBarApp"
[ -f "$BIN" ] || { echo "実行ファイルが見つからない: $BIN" >&2; exit 1; }

echo "==> バンドルを組み立てる"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AgentStatusBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>AgentStatusBar</string>
    <key>CFBundleDisplayName</key><string>Agent Status Bar</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>AgentStatusBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Dock にアイコンを出さない。メニューバーのみに常駐する -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# 通知の許可取得には署名済みであることが必要。配布しないので ad-hoc で足りる。
echo "==> ad-hoc 署名"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 \
    || echo "   署名に失敗した（通知が出ない可能性がある）" >&2

echo "できあがり: $APP"
