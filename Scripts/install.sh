#!/bin/bash
# ビルドして /Applications にインストールする。
#
# 「ログイン時に起動」は登録した時点の .app の場所を記憶するため、
# ビルドごとに作り直される build/ の中ではなく固定の場所に置く必要がある。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID="dev.knagatani.AgentStatusBar"
DEST_DIR="/Applications"
DEST="$DEST_DIR/AgentStatusBar.app"

"$ROOT/Scripts/make-app.sh" release
SRC="$ROOT/build/AgentStatusBar.app"

# 書き込めない場合は ~/Applications にする
if [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    DEST="$DEST_DIR/AgentStatusBar.app"
    mkdir -p "$DEST_DIR"
    echo "==> /Applications に書き込めないため $DEST_DIR を使う"
fi

echo "==> 起動中のインスタンスを終了"
pkill -f "AgentStatusBar.app/Contents/MacOS/AgentStatusBar" 2>/dev/null || true
sleep 1

# 既存を置き換える前に、それが本当に自分のアプリか確認する
if [ -e "$DEST" ]; then
    existing="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST/Contents/Info.plist" 2>/dev/null || echo '')"
    if [ "$existing" != "$BUNDLE_ID" ]; then
        echo "$DEST は別のアプリ ($existing) です。中止します。" >&2
        exit 1
    fi
    rm -rf "$DEST"
fi

echo "==> $DEST へコピー"
cp -R "$SRC" "$DEST"

echo "==> 起動"
open "$DEST"
echo ""
echo "インストール先: $DEST"
echo "「ログイン時に起動」はこの場所を記憶します。"
echo "アプリを移動した場合は、設定でいったんオフにしてから入れ直してください。"
