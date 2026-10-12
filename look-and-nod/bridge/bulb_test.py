"""
Bulb test for Look and Nod.
Put this file in the same folder as devices.json and snapshot.json, then run:
    python3 bulb_test.py
It reads your bulb's details from those files, so your key never has to be typed or shared.
"""
import json
import time
import tinytuya

with open("devices.json") as f:
    dev = json.load(f)[0]

ip = dev.get("ip") or "192.168.0.133"
version = None
try:
    with open("snapshot.json") as f:
        for d in json.load(f).get("devices", []):
            if d.get("id") == dev["id"]:
                ip = d.get("ip") or ip
                version = float(d.get("ver") or d.get("version") or 0) or None
except FileNotFoundError:
    pass
version = version or float(dev.get("version") or 0) or 3.3

print(f"Bulb: {dev.get('name')}  IP: {ip}  protocol version: {version}")

bulb = tinytuya.BulbDevice(dev["id"], ip, dev["key"], version=version)
bulb.set_socketPersistent(True)

def step(label, fn):
    print(label)
    result = fn()
    if isinstance(result, dict) and result.get("Error"):
        print("   Problem:", result["Error"])
    time.sleep(1.5)

step("Turning off...", bulb.turn_off)
step("Turning on...", bulb.turn_on)
step("Red...", lambda: bulb.set_colour(255, 0, 0))
step("Green...", lambda: bulb.set_colour(0, 255, 0))
step("Back to white, full brightness...", lambda: bulb.set_white_percentage(100, 50))
step("Dim to 20%...", lambda: bulb.set_white_percentage(20, 50))
step("Full brightness again...", lambda: bulb.set_white_percentage(100, 50))

print("\nStatus now:", bulb.status())
print("Done. If the bulb did all of that, the bulb side is working.")
