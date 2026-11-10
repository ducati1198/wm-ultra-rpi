"""KlipperScreen opens TWO Moonraker connections when Moonraker restarts (two reconnect timers fire before the first
connection is up), so every popup / message arrives twice (two OK and two Cancel buttons). connect() only checks
"already connected"; also refuse while a socket thread from an earlier call is still running. Idempotent.
usage: patch_ks_ws.py /path/to/KlipperScreen/ks_includes/KlippyWebsocket.py"""
import sys

p = sys.argv[1]
s = open(p).read()
if "wm: one connection only" in s:
    sys.exit(0)
a = '''        if self.connected:
            logging.debug("Already connected")
            return False
        self.closing = False
'''
b = '''        if self.connected:
            logging.debug("Already connected")
            return False
        if getattr(self, "_wst", None) is not None and self._wst.is_alive():   # wm: one connection only
            logging.debug("Connection already in progress")
            return False
        self.closing = False
'''
if s.count(a) != 1:
    sys.exit(1)
open(p, "w").write(s.replace(a, b, 1))
