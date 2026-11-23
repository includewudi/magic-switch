#!/bin/bash
# 构建 MagicSwitch.app（无需 Xcode 工程，swiftc 直接编译）
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p build
swiftc -O -parse-as-library \
  -o build/MagicSwitch \
  Sources/AgentClient.swift Sources/Switcher.swift Sources/HotkeyManager.swift Sources/MagicSwitchApp.swift

rm -rf MagicSwitch.app
mkdir -p MagicSwitch.app/Contents/MacOS
cp build/MagicSwitch MagicSwitch.app/Contents/MacOS/MagicSwitch
cp Info.plist MagicSwitch.app/Contents/Info.plist

codesign --force -s - MagicSwitch.app
echo "BUILD OK: $(pwd)/MagicSwitch.app"
