#!/bin/bash
# 部署 bt-agent 到 Mac Studio（经 SSH）
set -euo pipefail
cd "$(dirname "$0")/.."

KEY="$HOME/.ssh/id_ed25519_nopass"
HOST="wudis@wudisdeMac-Studio.local"
TOKEN="${MAGIC_TOKEN:-CHANGE_ME}"
REMOTE_HOME="/Users/wudis"

echo "==> 传输文件"
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" \
    /opt/homebrew/bin/blueutil "$HOST":/tmp/blueutil
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" \
    agent/bt-agent "$HOST":/tmp/bt-agent

echo "==> 写配置与 plist"
ssh -o BatchMode=yes -o IdentitiesOnly=yes -i "$KEY" "$HOST" bash -s <<REMOTE
set -euo pipefail
mkdir -p ~/.local/bin ~/.config/bt-agent ~/Library/LaunchAgents
mv -f /tmp/blueutil /opt/homebrew/bin/blueutil
chmod 755 /opt/homebrew/bin/blueutil
mv -f /tmp/bt-agent ~/.local/bin/bt-agent
chmod 755 ~/.local/bin/bt-agent

cat > ~/.config/bt-agent/config.json <<CFG
{
  "token": "${TOKEN}",
  "listen": "0.0.0.0:19821",
  "devices": ["PENDING-PAIR-KB", "PENDING-PAIR-MOUSE"]
}
CFG

cat > ~/Library/LaunchAgents/com.magicswitch.agent.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.magicswitch.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>${REMOTE_HOME}/.local/bin/bt-agent</string>
    <string>-config</string>
    <string>${REMOTE_HOME}/.config/bt-agent/config.json</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/bt-agent.log</string>
  <key>StandardErrorPath</key><string>/tmp/bt-agent.log</string>
</dict>
</plist>
PLIST

launchctl bootout gui/\$(id -u)/com.magicswitch.agent 2>/dev/null || true
launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/com.magicswitch.agent.plist
launchctl kickstart -k gui/\$(id -u)/com.magicswitch.agent
sleep 1
echo "==> health: \$(curl -s http://127.0.0.1:19821/health)"
REMOTE

echo "==> 从 MacBook 验证局域网可达"
curl -s --connect-timeout 3 "http://192.168.0.54:19821/health" && echo " <- STUDIO AGENT OK"
