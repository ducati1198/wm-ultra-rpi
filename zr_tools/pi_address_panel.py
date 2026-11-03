# "Pi address" panel for the WonderMaker screen board. Installed as KlipperScreen/panels/pi_address.py and added to the
# More menu and to the start screen (the one shown while the Pi cannot be reached), so the address can be fixed on the screen.

import logging
import os
import signal

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

from ks_includes.screen_panel import ScreenPanel  # noqa: E402

try:
    from panels import zr_logic as L  # noqa: E402
except ImportError:
    import zr_logic as L  # noqa: E402

CONF = os.path.expanduser("~/printer_data/config/KlipperScreen.conf")


class Panel(ScreenPanel):
    def __init__(self, screen, title):
        super().__init__(screen, title or "Pi address")
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        try:
            with open(CONF) as f:
                self.text = f.read()
        except OSError:
            self.text = ""
        cur = L.read_moonraker_host(self.text)
        lbl = Gtk.Label(label="IP address (or name) of the Raspberry Pi that runs Klipper.\nNow: %s" % (cur or "not set"))
        lbl.set_xalign(0)
        lbl.set_line_wrap(True)
        box.pack_start(lbl, False, False, 0)
        self.entry = Gtk.Entry()
        self.entry.set_text(cur)
        box.pack_start(self.entry, False, False, 0)
        row = Gtk.Box(spacing=8)
        save = self._gtk.Button("complete", "Save and restart", "color3")
        save.connect("clicked", self.save)
        row.pack_start(save, True, True, 0)
        box.pack_start(row, False, False, 0)
        self.content.add(box)
        self.content.show_all()
        for ev in ("button-press-event", "touch-event"):   # same as KlipperScreen's own panels
            self.entry.connect(ev, self._screen.show_keyboard)
        GLib.timeout_add(400, self._open_keyboard, self.entry)

    def _open_keyboard(self, entry):
        try:
            entry.grab_focus()
            self._screen.show_keyboard(entry=entry)
        except Exception:
            logging.exception("could not open the on-screen keyboard")
        return False

    def save(self, _w=None):
        host = self.entry.get_text().strip()
        if not L.valid_host(host):
            self._screen.show_popup_message("Use an IP address like 192.168.0.50 or a name (letters, digits, dots, dashes).")
            return
        new = L.replace_moonraker_host(self.text, host)
        if new is None:
            self._screen.show_popup_message("No moonraker_host line in KlipperScreen.conf.")
            return
        try:
            tmp = CONF + ".new"
            with open(tmp, "w") as f:
                f.write(new)
            os.replace(tmp, CONF)
        except OSError as e:
            self._screen.show_popup_message("Could not save: %s" % e)
            return
        self._screen.show_popup_message("Saved. Restarting KlipperScreen...", 1)
        logging.info("Pi address set to %s, restarting", host)
        # the service restarts KlipperScreen by itself when it exits
        GLib.timeout_add(1200, lambda: os.kill(os.getpid(), signal.SIGTERM))
