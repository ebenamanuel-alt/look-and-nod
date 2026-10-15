import json, re, threading, tinytuya
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT = 8765

# Colours the Magic Mouse swipe steps through. Change or add your own.
# ("Name", "white", warmth 0 warm to 100 cool)  or  ("Name", "colour", (red, green, blue))
PRESETS = [
    ("Warm white", "white", 0),
    ("Neutral white", "white", 50),
    ("Cool white", "white", 100),
    ("Red", "colour", (255, 0, 0)),
    ("Orange", "colour", (255, 100, 0)),
    ("Green", "colour", (0, 255, 60)),
    ("Blue", "colour", (0, 70, 255)),
    ("Purple", "colour", (160, 0, 255)),
]

def slug(n): return re.sub(r"[^a-z0-9]+", "-", n.lower()).strip("-") or "device"
def load_devices():
    devices = json.load(open("devices.json"))
    snap = {}
    try:
        for d in json.load(open("snapshot.json")).get("devices", []): snap[d.get("id")] = d
    except FileNotFoundError: pass
    bulbs = {}
    for d in devices:
        if not d.get("key"): continue
        s = snap.get(d["id"], {}); ip = s.get("ip") or d.get("ip") or "Auto"
        v = float(s.get("ver") or s.get("version") or d.get("version") or 3.3)
        b = tinytuya.BulbDevice(d["id"], ip, d["key"], version=v)
        b.set_socketPersistent(True); b.set_socketTimeout(2)
        name = slug(d.get("name") or d["id"])
        bulbs[name] = {"bulb": b, "lock": threading.Lock(), "label": d.get("name") or name, "level": None, "preset": 0}
        print(f"  {name}  {ip}  v{v}")
    return bulbs
BULBS = {}
ALL = {"preset": 0}
ACTIONS = ("on", "off", "toggle", "status", "step", "brightness", "preset")

def failed(r): return isinstance(r, dict) and r.get("Error")
def current_level(e):
    if e["level"] is None:
        try: e["level"] = int(round(e["bulb"].get_brightness_percentage()))
        except Exception: e["level"] = 100
    return e["level"]
def set_level(e, pct):
    pct = max(5, min(100, int(pct)))
    r = e["bulb"].set_brightness_percentage(pct)
    if not failed(r): e["level"] = pct
    return r
def is_on(b): return bool((b.status() or {}).get("dps", {}).get("1"))
def next_index(current, arg):
    if arg == "next": return (current + 1) % len(PRESETS)
    if arg == "prev": return (current - 1) % len(PRESETS)
    return int(arg) % len(PRESETS)
def apply_preset(e, i):
    name, kind, value = PRESETS[i]
    b = e["bulb"]; b.turn_on(); level = current_level(e)
    if kind == "white":
        r = b.set_white_percentage(brightness=level, colourtemp=value)
    else:
        r = b.set_colour(*value)
        if not failed(r) and level < 100:
            try: b.set_brightness_percentage(level)
            except Exception: pass
    if not failed(r): e["preset"] = i
    return r, name

def act_locked(e, action, arg):
    b = e["bulb"]
    if action == "on": return b.turn_on(), {}
    if action == "off": return b.turn_off(), {}
    if action == "toggle":
        on = is_on(b)
        return (b.turn_off() if on else b.turn_on()), {"action": "off" if on else "on"}
    if action == "status": return b.status(), {}
    if action == "step": return set_level(e, current_level(e) + int(arg)), {}
    if action == "brightness": return set_level(e, int(arg)), {}
    r, name = apply_preset(e, next_index(e["preset"], arg))
    return r, {"preset": name}

def act(name, action, arg=None):
    if action not in ACTIONS: return 400, {"error": "Use on, off, toggle, status, step, brightness or preset"}
    if name == "all": return act_all(action, arg)
    e = BULBS.get(name)
    if not e: return 404, {"error": f"No device called '{name}'"}
    try:
        with e["lock"]: r, extra = act_locked(e, action, arg)
    except (TypeError, ValueError): return 400, {"error": "Use step/10, brightness/50 or preset/next"}
    if failed(r): return 502, {"error": r["Error"]}
    body = {"ok": True, "device": name, "action": action, "level": e["level"] if e["level"] is not None else 100}
    body.update(extra)
    return 200, body

def act_all(action, arg):
    if not BULBS: return 404, {"error": "No bulbs loaded"}
    try:
        if action in ("step", "brightness"): int(arg)
        if action == "preset": ALL["preset"] = next_index(ALL["preset"], arg); arg = str(ALL["preset"])
    except (TypeError, ValueError): return 400, {"error": "Use step/10, brightness/50 or preset/next"}
    if action == "toggle":
        # If any light is on, switch them all off. Otherwise switch them all on.
        def check(e):
            try:
                with e["lock"]: return is_on(e["bulb"])
            except Exception: return False
        with ThreadPoolExecutor() as ex: action = "off" if any(ex.map(check, BULBS.values())) else "on"
    def run(item):
        name, e = item
        try:
            with e["lock"]: r, _ = act_locked(e, action, arg)
            return name, (r["Error"] if failed(r) else None)
        except Exception as x: return name, str(x)
    with ThreadPoolExecutor() as ex: results = dict(ex.map(run, BULBS.items()))
    errors = {k: v for k, v in results.items() if v}
    if len(errors) == len(results): return 502, {"error": "; ".join(f"{k}: {v}" for k, v in errors.items())}
    levels = {k: (e["level"] if e["level"] is not None else 100) for k, e in BULBS.items()}
    body = {"ok": True, "device": "all", "action": action, "levels": levels,
            "level": round(sum(levels.values()) / len(levels))}
    if action == "preset": body["preset"] = PRESETS[ALL["preset"]][0]
    if errors: body["errors"] = errors
    return 200, body

class H(BaseHTTPRequestHandler):
    def send(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data))); self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        p = [x for x in self.path.split("?")[0].split("/") if x]
        if not p or p == ["devices"]:
            return self.send(200, {"devices": [{"name": k, "label": v["label"]} for k, v in BULBS.items()]})
        if len(p) in (2, 3):
            code, body = act(p[0], p[1], p[2] if len(p) == 3 else None)
            extra = ""
            if code == 200 and "preset" in body: extra = f" ({body['preset']})"
            elif code == 200 and p[1] in ("step", "brightness"): extra = f" ({body['level']}%)"
            print(f"{p[0]} -> {'/'.join(p[1:])}: {'ok' if code == 200 else body['error']}{extra}", flush=True)
            return self.send(code, body)
        self.send(404, {"error": "Use /devices or /<device>/<on|off|toggle|step/10|preset/next>"})
    def log_message(self, *a): pass

if __name__ == "__main__":
    print("Loading bulbs:", flush=True); BULBS.update(load_devices())
    print(f"Bulb bridge running on http://127.0.0.1:{PORT}  (Ctrl+C to stop)", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
