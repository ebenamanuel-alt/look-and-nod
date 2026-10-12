#!/bin/bash
DIR="$HOME/Library/Application Support/LookAndNod"
PLIST="$HOME/Library/LaunchAgents/com.lookandnod.bridge.plist"
read -r -p "Remove the Look and Nod helper and your saved bulb details? (y/N): " a
if [[ "$a" =~ ^[Yy] ]]; then
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null
  rm -f "$PLIST"; rm -rf "$DIR"
  echo "Removed. Drag the Look and Nod app to the Bin to finish."
fi
read -n 1 -s -r -p "Press any key to close this window."; echo
