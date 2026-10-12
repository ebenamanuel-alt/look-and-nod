# Look and Nod: setting up

Look at a light, hold Control and Option, and nod to switch it on or shake your head to switch it off. Hold Control and Option and press ↑ or ↓, or swipe up or down on your AirPods, to change brightness.

## What you need

* A Mac with macOS 14 or newer
* AirPods that track your head: AirPods Pro, AirPods Max, or AirPods 3rd generation or newer
* Smart bulbs that work with the **Smart Life** or **Tuya Smart** app (for example TCP Smart, Calex, Lidl Livarno, Teckin and many own brand bulbs)
* Your Mac and bulbs on the same WiFi

It takes about 15 minutes, once.

## 1. Get your bulb keys from Tuya

Your bulbs only accept commands that come with a secret key. Tuya gives you that key through a free developer account.

1. Make sure your bulbs work in the **Smart Life** app on your phone.
2. Sign up at [iot.tuya.com](https://iot.tuya.com).
3. Go to **Cloud → Development → Create Cloud Project**:
   * Development Method: **Smart Home**
   * Industry: **Smart Home**
   * Data Center: **Central Europe** in the UK or Europe, **Western America** in the US
4. Accept the suggested services and click **Authorize**.
5. On the **Overview** page, keep the **Access ID** and **Access Secret** handy.
6. Open **Devices → Link App Account → Add App Account**. Scan the QR code **inside the Smart Life app** (Me, then the scan icon at the top right), not with your camera.
7. Your bulbs appear under Devices. Copy any one **Device ID**.

## 2. Run the setup

1. Right click **Setup Look and Nod.command** and choose **Open**, then **Open** again.
2. If your Mac asks to install command line tools, click **Install**, wait, then open the setup file again.
3. Paste in your **Access ID**, **Access Secret**, **Device ID**, and type `eu` (Europe) or `us` (America) for the region. Answer **Y** to both questions at the end.
4. If your Mac asks about devices on your local network, click **Allow**.

Your first light flicks off and on to show it works. A small helper now runs in the background and starts by itself when you log in.

## 3. Open the app

1. Drag **Look and Nod** into your Applications folder and open it.
2. The first time, macOS says it can't check the app. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**.
3. Allow **Motion & Fitness** when asked, so the app can read your AirPods.
4. In **System Settings → Privacy & Security → Accessibility**, turn on **Look and Nod**, so the shortcut works in every app.

## 4. Use it

The **Get started** checklist in the app ticks off each step.

1. Put your AirPods in, face your screen and press **Recentre**.
2. Look at a light and choose **Save Direction** on its card.
3. Hold **⌃ Control + ⌥ Option**, look at the light and **nod** to switch it on, or **shake** to switch it off.
4. Keep holding ⌃ ⌥ and press **↑ ↓**, or swipe your AirPods stem, for brightness.

Options at the top of the room:

* **Hold ⌃ ⌥ / Always**: listen only while you hold the keys, or all the time.
* **Look to pick / From desk**: choose a light by looking at it, or control chosen lights without looking.

## If something isn't working

* **Bridge shows orange**: open the setup file again. It restarts the helper.
* **Lights found but nothing happens**: check the bulb is on at the wall, then turn on **python** in System Settings → Privacy & Security → Local Network.
* **Shortcut shows orange**: in Accessibility settings, remove Look and Nod with the minus button, add it again, then reopen the app.
* **AirPods show orange**: connect them to the Mac, not your phone, and play something for a second.
* **You reset or re-paired a bulb, or added a new one**: open the setup file and answer **y** to set the bulbs up again.

To remove everything, open **Uninstall Look and Nod.command**, then drag the app to the Bin.
