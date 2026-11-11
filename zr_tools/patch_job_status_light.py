"""Add a Light button (chamber light) to KlipperScreen's print screen (job_status.py) while printing or paused.
The button is only added when the root helper /usr/local/sbin/wm-chamber-light exists. Idempotent.
usage: patch_job_status_light.py /path/to/KlipperScreen/panels/job_status.py"""
import sys

p = sys.argv[1]
s = open(p).read()
if "wm_chamber_light" in s:
    sys.exit(0)

a = '        self.buttons["control"].connect("clicked", self._screen._go_to_submenu, "")\n'
if s.count(a) != 1:
    sys.exit(1)
s = s.replace(a, a + '''        # WonderMaker: chamber light button (only when the helper is installed)
        self.buttons["wm_light"] = self._gtk.Button("light", _("Light"), "color3")
        self.buttons["wm_light"].connect("clicked", self.wm_chamber_light)
''', 1)

b = '            self.buttons["button_grid"].attach(self.buttons["control"], 3, 0, 1, 1)\n'
if s.count(b) != 2:
    sys.exit(1)
s = s.replace(b, b + '''            if os.path.exists("/usr/local/sbin/wm-chamber-light"):
                self.buttons["button_grid"].attach(self.buttons["wm_light"], 4, 0, 1, 1)
''')

method = '''
    def wm_chamber_light(self, widget):
        # WonderMaker: toggle the chamber light (root helper through sudo -n)
        import subprocess
        import threading
        from gi.repository import GLib

        import logging

        def work():
            try:
                r = subprocess.run(["sudo", "-n", "/usr/local/sbin/wm-chamber-light", "toggle"],
                                   capture_output=True, text=True, timeout=8)
                ok = r.returncode == 0
                logging.info("chamber light: rc=%s out=%r err=%r", r.returncode, r.stdout, r.stderr)
            except Exception:
                logging.exception("chamber light toggle failed")
                ok = False
            GLib.idle_add(done, ok)

        def done(ok):
            try:
                self._gtk.Button_busy(widget, False)
                if not ok:
                    self._screen.show_popup_message("The chamber light helper is not installed.")
            except Exception:
                logging.exception("chamber light: could not reset the button")
            return False

        def watchdog():   # never leave the button spinning
            try:
                self._gtk.Button_busy(widget, False)
            except Exception:
                logging.exception("chamber light: watchdog")
            return False

        logging.info("chamber light: button pressed")
        self._gtk.Button_busy(widget, True)
        GLib.timeout_add_seconds(12, watchdog)
        threading.Thread(target=work, daemon=True).start()
'''
i = s.index("\n    def save_offset(self, widget, device):")
s = s[:i] + method + s[i:]
if "\nimport os\n" not in s:
    s = "import os\n" + s if not s.startswith(("#", '"')) else s.replace("\nimport ", "\nimport os\nimport ", 1)
open(p, "w").write(s)
