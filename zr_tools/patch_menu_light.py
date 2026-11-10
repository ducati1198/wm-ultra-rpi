"""Make the main-menu button "method: wm_chamber_light" toggle the chamber light directly (no page). Idempotent.
usage: patch_menu_light.py /path/to/KlipperScreen/panels/menu.py"""
import re
import sys

MARK = "wm_chamber_light"
p = sys.argv[1]
s = open(p).read()
if MARK in s:
    sys.exit(0)
a = '            elif item["method"] == "ks_confirm_save":\n'
if a not in s:
    sys.exit(1)
s = s.replace(a, '            elif item["method"] == "wm_chamber_light":\n                b.connect("clicked", self.wm_chamber_light)\n' + a, 1)
method = '''
    def wm_chamber_light(self, widget):
        # WonderMaker: toggle the chamber light (root helper through sudo -n), no page
        import subprocess
        import threading
        from gi.repository import GLib

        def work():
            try:
                r = subprocess.run(["sudo", "-n", "/usr/local/sbin/wm-chamber-light", "toggle"],
                                   capture_output=True, text=True, timeout=8)
                ok = r.returncode == 0
            except Exception:
                ok = False
            GLib.idle_add(done, ok)

        def done(ok):
            self._gtk.Button_busy(widget, False)
            if not ok:
                self._screen.show_popup_message("The chamber light helper is not installed.")
            return False

        self._gtk.Button_busy(widget, True)
        threading.Thread(target=work, daemon=True).start()
'''
m = re.search(r"\n    def create_menu_items\(self\):", s)
s = s[:m.start()] + method + s[m.start():]
open(p, "w").write(s)
