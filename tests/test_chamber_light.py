"""Chamber light: the board's network service (wm-chamber-light-http) with a fake helper, the registration upload
against a fake Moonraker, and the root helper script against a fake sysfs folder."""
import http.client
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer, ThreadingHTTPServer

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
passed = failed = 0


def check(name, cond):
    global passed, failed
    if cond:
        passed += 1
        print("  ok   ", name)
    else:
        failed += 1
        print("  FAIL ", name)


tmp = tempfile.mkdtemp()
fake = os.path.join(tmp, "helper.sh")
state = os.path.join(tmp, "state")
open(fake, "w").write('#!/bin/sh\nf=%s; [ -f $f ] || echo off > $f\ncase $1 in on|off) echo $1 > $f;; toggle) [ "$(cat $f)" = on ] && echo off > $f || echo on > $f;; esac\ncat $f\n' % state)
os.chmod(fake, 0o755)

src = open(os.path.join(ROOT, "zr_tools", "wm-chamber-light-http")).read().replace('HELPER = "/usr/local/sbin/wm-chamber-light"', 'HELPER = "%s"' % fake)
svc_path = os.path.join(tmp, "svc.py")
open(svc_path, "w").write(src)
loader = importlib.machinery.SourceFileLoader("svc", svc_path)
spec = importlib.util.spec_from_loader("svc", loader)
svc = importlib.util.module_from_spec(spec)
loader.exec_module(svc)

srv = ThreadingHTTPServer(("127.0.0.1", 0), svc.Handler)
port = srv.server_address[1]
threading.Thread(target=srv.serve_forever, daemon=True).start()


def call(method, path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
    c.request(method, path, body=body)
    r = c.getresponse()
    data = r.read()
    return r.status, dict(r.getheaders()), (json.loads(data) if data else None)


print("network service")
st, h, d = call("GET", "/light")
check("GET /light says off at first", st == 200 and d == {"on": False})
check("answers carry the CORS header the Fluidd page needs", h.get("Access-Control-Allow-Origin") == "*")
st, _, d = call("POST", "/light/toggle")
check("POST /light/toggle turns it on", st == 200 and d == {"on": True})
st, _, d = call("POST", "/light", json.dumps({"on": False}))
check("POST /light {on:false} turns it off", st == 200 and d == {"on": False})
st, _, d = call("POST", "/light", json.dumps({"on": "yes"}))
check("a body that is not true/false is refused", st == 400)
st, _, _ = call("GET", "/nothing")
check("other paths are 404", st == 404)
st, _, _ = call("OPTIONS", "/light")
check("OPTIONS (browser preflight) is answered", st == 204)

print("registration upload")
got = {}


class FakeMoonraker(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        got["path"] = self.path
        got["body"] = self.rfile.read(int(self.headers["Content-Length"])).decode()
        self.send_response(201)
        self.end_headers()
        self.wfile.write(b"{}")


try:
    mr = HTTPServer(("127.0.0.1", 7125), FakeMoonraker)
except OSError:
    mr = None
if mr:
    threading.Thread(target=mr.serve_forever, daemon=True).start()
    conf = os.path.join(tmp, "KlipperScreen.conf")
    open(conf, "w").write("[printer X]\nmoonraker_host: 127.0.0.1\n")
    ok = svc.register(conf, 8765)
    check("register uploads wm_chamber_light.json into the config folder", ok and got.get("path") == "/server/files/upload" and 'filename="wm_chamber_light.json"' in got["body"] and "config" in got["body"] and '"url": "http://127.0.0.1:8765"' in got["body"])
    check("no conf file means no upload and no crash", svc.register(os.path.join(tmp, "none.conf"), 8765) is False)
    mr.shutdown()
else:
    print("  (port 7125 is busy here: registration test skipped)")

print("root helper (fake sysfs)")
helper_src = open(os.path.join(ROOT, "zr_tools", "wm-chamber-light")).read()
gpio = os.path.join(tmp, "gpio")
os.makedirs(os.path.join(gpio, "gpio76"))
open(os.path.join(gpio, "export"), "w").close()
open(os.path.join(gpio, "gpio76", "value"), "w").write("0\n")
open(os.path.join(gpio, "gpio76", "direction"), "w").write("in\n")
hp = os.path.join(tmp, "wm-chamber-light")
open(hp, "w").write(helper_src.replace("G=/sys/class/gpio", "G=%s" % gpio).replace("STATE_DIR=/var/lib/wm-chamber-light", "STATE_DIR=%s" % os.path.join(tmp, "var")))
os.chmod(hp, 0o755)


def run(arg):
    return subprocess.run([hp, arg], capture_output=True, text=True).stdout.strip()


check("status starts off", run("status") == "off")
check("on writes 1 to gpio76 and sets direction out", run("on") == "on" and open(os.path.join(gpio, "gpio76", "value")).read().strip() == "1" and open(os.path.join(gpio, "gpio76", "direction")).read().strip() == "out")
check("toggle turns it off", run("toggle") == "off" and open(os.path.join(gpio, "gpio76", "value")).read().strip() == "0")
run("on")
open(os.path.join(gpio, "gpio76", "value"), "w").write("0\n")   # a reboot clears the pin
check("restore puts it back to the saved state (on)", run("restore") == "on" and open(os.path.join(gpio, "gpio76", "value")).read().strip() == "1")
check("an unknown argument is refused", subprocess.run([hp, "bogus"], capture_output=True).returncode == 2)

print("passed: %d   failed: %d" % (passed, failed))
sys.exit(1 if failed else 0)
