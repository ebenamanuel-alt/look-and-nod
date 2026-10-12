import json, os, re, sys, threading, tinytuya
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = 8765
os.chdir(os.path.dirname(os.path.abspath(__file__)))

def slug(n): return re.sub(r"[^a-z0-9]+", "-", n.lower()).strip("-") or "device"

def connect(d, ip, version):
    b = tinytuya.BulbDevice(d["id"], ip or "Auto", d["key"], version=version or 3.3)
    b.set_socketPersistent(True); b.set_socketTimeout(2); b.set_socketRetryLimit(1)
    return b

def load_devices():
    try:
        devices = json.load(open("devices.json"))
    except FileNotFoundError:
        print("No devices.json here. Run Setup Look and Nod first."); sys.exit(1)
    snap = {}
    try:
        for d in json.load(open("snapshot.json")).get("devices", []): snap[d.get("id")] = d
    except (FileNotFoundError, ValueError): pass
    bulbs, taken = {}, set()
    for d in devices:
        if not d.get("key"): continue
        s = snap.get(d["id"], {})
        ip = s.get("ip") or d.get("ip") or None
        v = float(s.get("ver") or s.get("version") or d.get("version") or 3.3)
        name = slug(d.get("name") or d["id"])
        while name in taken: name += "-2"
        taken.add(name)
        try:
            b = connect(d, ip, v)
        except Exception as ex:
            print(f"  {name}: not found on the network yet ({ex})"); b = None
        bulbs[name] = {"info": d, "ip": ip, "ver": v, "bulb": b, "lock": threading.Lock(),
                       "label": d.get("name") or name, "level": None}
        print(f"  {name}  {ip or 'finding automatically'}  v{v}")
    return bulbs

BULBS = {}

def failed(r): return r is None or (isinstance(r, dict) and r.get("Error"))

def rediscover(e):
    """The bulb may have a new IP address. Look for it on the network by its ID."""
    print(f"  looking for {e['label']} on the network...")
    try:
        e["bulb"] = connect(e["info"], None, None)
        e["ip"] = e["bulb"].address
        print(f"  found {e['label']} at {e['ip']}")
        return True
    except Exception as ex:
        print(f"  couldn't find {e['label']}: {ex}")
        return False

def current_level(e):
    if e["level"] is None:
        try: e["level"] = int(round(e["bulb"].get_brightness_percentage()))
        except Exception: e["level"] = 100
    return e["level"]

def do(e, action, arg):
    b = e["bulb"]
    if b is None: return {"Error": "Bulb not found on the network"}
    if action == "on": return b.turn_on()
    if action == "off": return b.turn_off()
    if action == "status": return b.status()
    if action == "toggle":
        on = bool((b.status() or {}).get("dps", {}).get("1") or (b.status() or {}).get("dps", {}).get("20"))
        return b.turn_off() if on else b.turn_on()
    if action in ("step", "brightness"):
        pct = current_level(e) + int(arg) if action == "step" else int(arg)
        pct = max(5, min(100, pct))
        r = b.set_brightness_percentage(pct)
        if not failed(r): e["level"] = pct
        return r
    raise ValueError

def act(name, action, arg=None):
    e = BULBS.get(name)
    if not e: return 404, {"error": f"No device called '{name}'"}
    if action not in ("on", "off", "toggle", "status", "step", "brightness"):
        return 400, {"error": "Use on, off, toggle, status, step or brightness"}
    if action in ("step", "brightness"):
        try: int(arg)
        except (TypeError, ValueError): return 400, {"error": f"Use /{name}/{action}/<number>"}
    with e["lock"]:
        try: r = do(e, action, arg)
        except Exception as ex: r = {"Error": str(ex)}
        if failed(r) and rediscover(e):
            try: r = do(e, action, arg)
            except Exception as ex: r = {"Error": str(ex)}
    if failed(r): return 502, {"error": (r or {}).get("Error", "No reply from the bulb")}
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
            print(f"{p[0]} -> {'/'.join(p[1:])}: {'ok' if code == 200 else body['error']}{extra}", flush=True)
            return self.send(code, body)
        self.send(404, {"error": "Use /devices or /<device>/<on|off|step/10>"})
    def log_message(self, *a): pass

if __name__ == "__main__":
    print("Loading bulbs:", flush=True); BULBS.update(load_devices())
    print(f"Bulb bridge running on http://127.0.0.1:{PORT}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
