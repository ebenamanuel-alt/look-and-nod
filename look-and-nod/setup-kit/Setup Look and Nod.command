#!/bin/bash
# Look and Nod setup. Double click this file to run it.

DIR="$HOME/Library/Application Support/LookAndNod"
PLIST="$HOME/Library/LaunchAgents/com.lookandnod.bridge.plist"
HERE="$(cd "$(dirname "$0")" && pwd)"
B=$'\033[1m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'

finish() { echo; read -n 1 -s -r -p "Press any key to close this window."; echo; exit "${1:-0}"; }

clear
echo "${B}Look and Nod setup${N}"
echo "This connects your Tuya / Smart Life bulbs and keeps a small helper running"
echo "in the background so the Look and Nod app can switch them."
echo

# 1. Python
PY="$(command -v python3)"
if [ -z "$PY" ] || ! "$PY" -c "import sys; assert sys.version_info >= (3, 8)" 2>/dev/null; then
  echo "${R}Your Mac needs Apple's free command line tools first.${N}"
  echo "A window will pop up. Click Install, wait for it to finish, then double click this file again."
  xcode-select --install 2>/dev/null
  finish 1
fi

if [ ! -f "$HERE/bulb_server.py" ]; then
  echo "${R}bulb_server.py is missing. Keep it in the same folder as this file.${N}"; finish 1
fi

# 2. Install the helper
echo "${B}Step 1 of 3: installing the helper${N}"
mkdir -p "$DIR"
if [ ! -x "$DIR/venv/bin/python" ]; then
  "$PY" -m venv "$DIR/venv" || { echo "${R}Couldn't create the helper folder.${N}"; finish 1; }
fi
"$DIR/venv/bin/python" -m pip install --quiet --upgrade pip tinytuya || { echo "${R}Install failed. Check your internet connection and try again.${N}"; finish 1; }
cp "$HERE/bulb_server.py" "$DIR/bulb_server.py"
echo "${G}Done.${N}"
echo

# 3. Find the bulbs
echo "${B}Step 2 of 3: finding your bulbs${N}"
cd "$DIR"
RUN_WIZARD=yes
if [ -s devices.json ]; then
  read -r -p "You've set up bulbs before. Set them up again? (y/N): " a
  [[ "$a" =~ ^[Yy] ]] || RUN_WIZARD=no
fi
if [ "$RUN_WIZARD" = yes ]; then
  echo
  echo "Have your Tuya developer details open (see the README). You'll be asked for:"
  echo "  API Key       the Access ID from your Tuya cloud project"
  echo "  API Secret    the Access Secret from the same page"
  echo "  Device ID     any one device ID from the Devices tab, or type scan"
  echo "  Region        eu for Central Europe (UK), us for America"
  echo "Answer Y to both questions at the end."
  echo
  "$DIR/venv/bin/python" -m tinytuya wizard
  if [ ! -s devices.json ]; then
    echo "${R}No bulbs were saved. Check the details and run this file again.${N}"; finish 1
  fi
fi
echo

# 4. Run the helper in the background, now and every time the Mac starts
echo "${B}Step 3 of 3: starting the helper${N}"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
pkill -f "LookAndNod/bulb_server[.]py" 2>/dev/null
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.lookandnod.bridge</string>
  <key>ProgramArguments</key><array>
    <string>$DIR/venv/bin/python</string><string>-u</string><string>$DIR/bulb_server.py</string>
  </array>
  <key>WorkingDirectory</key><string>$DIR</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$DIR/bridge.log</string>
  <key>StandardErrorPath</key><string>$DIR/bridge.log</string>
</dict></plist>
PL
: > "$DIR/bridge.log"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

for i in $(seq 1 30); do
  OUT="$(curl -s --max-time 1 http://127.0.0.1:8765/devices)" && [ -n "$OUT" ] && break
  sleep 1
done
if [ -z "$OUT" ]; then
  echo "${R}The helper didn't start. Here's what it said:${N}"; tail -20 "$DIR/bridge.log"; finish 1
fi
echo "${G}The helper is running and will start by itself whenever you log in.${N}"
echo
echo "Your lights:"
"$DIR/venv/bin/python" -c "import json,sys; [print('  ' + d['label']) for d in json.loads(sys.argv[1])['devices']]" "$OUT"
echo
echo "${B}Quick test${N}: switching the first light off and on."
FIRST="$("$DIR/venv/bin/python" -c "import json,sys; d=json.loads(sys.argv[1])['devices']; print(d[0]['name'] if d else '')" "$OUT")"
if [ -n "$FIRST" ]; then
  curl -s --max-time 25 "http://127.0.0.1:8765/$FIRST/off" >/dev/null; sleep 1.5
  R2="$(curl -s --max-time 25 "http://127.0.0.1:8765/$FIRST/on")"
  if [[ "$R2" == *'"ok": true'* ]]; then
    echo "${G}It worked. Now open the Look and Nod app.${N}"
  else
    echo "${R}The light didn't answer.${N} Check it is switched on at the wall. If macOS asked about devices on your local network, click Allow."
    echo "Otherwise go to System Settings, Privacy & Security, Local Network, turn on python, and run this again."
  fi
fi
finish 0
