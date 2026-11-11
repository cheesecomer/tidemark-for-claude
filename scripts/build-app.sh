#!/bin/bash
# リリースビルドして build/Tidemark.app を作る（Xcode 不要）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release

app=build/Tidemark.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Tidemark" "$app/Contents/MacOS/"
cp Resources/Info.plist "$app/Contents/"
codesign --force --sign - "$app"

echo "Built $app"
