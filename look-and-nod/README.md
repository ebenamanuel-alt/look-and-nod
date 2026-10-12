# Look and Nod

Control smart lights with your head using AirPods. Hold Control + Option, look at a light, nod for on and shake for off. Control + Option + ↑ ↓ or an AirPods swipe changes brightness.

## What's here

* `app/` the Mac app (latest dashboard). Paste `ContentView.swift` into an Xcode macOS App project, or run `bash app/build.sh` on a Mac to build `Look and Nod.app`.
* `bridge/bulb_server.py` the bulb bridge: put it next to `devices.json` and `snapshot.json` from the TinyTuya wizard and run `python3 bulb_server.py`. `bulb_test.py` checks a bulb works.
* `setup-kit/` a version for other people: double click setup and the bridge runs in the background.
* `older-versions/` the first simple app, and a version that uses Apple Home through Shortcuts.
* `web-demo/` a browser version that uses the webcam instead of AirPods.
* `website/` the landing page.
* `video/` the first demo video.

## Getting it running again

1. Xcode: new macOS App project, paste `app/ContentView.swift` over ContentView.
2. Info tab: add **Privacy - Motion Usage Description**.
3. Signing & Capabilities: remove **App Sandbox**.
4. Start the bridge: `python3 bulb_server.py` (needs `pip3 install tinytuya`, plus `devices.json` from `python3 -m tinytuya wizard`).
5. Run the app, allow Motion and Accessibility, press Recentre, save a light's direction.

Tuya platform: Smart Home project, Central Europe data centre, link the Smart Life app by scanning the QR code inside the app (Me, then the scan icon).
