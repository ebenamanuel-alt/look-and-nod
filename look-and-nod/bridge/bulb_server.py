import json, re, threading, tinytuya
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
PORT = 8765
def slug(n): return re.sub(r"[^a-z0-9]+", "-", n.lower()).strip("-") or "device"
def load_devices():
    devices = json.load(open("devices.json"))
    snap = {}
    try:
        for d in json.load(open("snapshot.json")).get("devices", []): snap[d.get("id")] = d
    except FileNotFoundError: pass
    bulbs = {}
    for d in devices:
        s = snap.get(d["id"], {}); ip = s.get("ip") or d.get("ip")
        if not ip: continue
        v = float(s.get("ver") or s.get("version") or d.get("version") or 3.3)
        b = tinytuya.BulbDevice(d["id"], ip, d["key"], version=v)
        b.set_socketPersistent(True); b.set_socketTimeout(2)
        name = slug(d.get("name") or d["id"])
        bulbs[name] = {"bulb": b, "lock": threading.Lock(), "label": d.get("name") or name, "level": None}
        print(f"  {name}  {ip}  v{v}")
    return bulbs
BULBS = {}
def current_level(e):
    if e["level"] is None:
        try: e["level"] = int(round(e["bulb"].get_brightness_percentage()))
        except Exception: e["level"] = 100
    return e["level"]
def set_level(e, pct):
    pct = max(5, min(100, int(pct)))
    r = e["bulb"].set_brightness_percentage(pct)
    if not (isinstance(r, dict) and r.get("Error")): e["level"] = pct
    return r
def act(name, action, arg=None):
    e = BULBS.get(name)
    if not e: return 404, {"error": f"No device called '{name}'"}
    b = e["bulb"]
    with e["lock"]:
        if action == "on": r = b.turn_on()
        elif action == "off": r = b.turn_off()
        elif action == "toggle":
            on = bool((b.status() or {}).get("dps", {}).get("1"))
            r = b.turn_off() if on else b.turn_on()
        elif action == "status": r = b.status()
        elif action == "step":
            try: delta = int(arg)
            except (TypeError, ValueError): return 400, {"error": "Use /<device>/step/10 or /<device>/step/-10"}
            r = set_level(e, current_level(e) + delta)
        elif action == "brightness":
            try: r = set_level(e, int(arg))
            except (TypeError, ValueError): return 400, {"error": "Use /<device>/brightness/50"}
        else: return 400, {"error": "Use on, off, toggle, status, step or brightness"}
    if isinstance(r, dict) and r.get("Error"): return 502, {"error": r["Error"]}
    return 200, {"ok": True, "device": name, "action": action, "level": e["level"] if e["level"] is not None else 100}
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
            extra = f" ({body['level']}%)" if code == 200 and p[1] in ("step", "brightness") else ""
            print(f"{p[0]} -> {'/'.join(p[1:])}: {'ok' if code == 200 else body['error']}{extra}")
            return self.send(code, body)
        self.send(404, {"error": "Use /devices or /<device>/<on|off|step/10>"})
    def log_message(self, *a): pass
print("Loading bulbs:"); BULBS.update(load_devices())
print(f"Bulb bridge running on http://127.0.0.1:{PORT}  (Ctrl+C to stop)")
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
