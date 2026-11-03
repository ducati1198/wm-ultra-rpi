# Wi-Fi panel for the WonderMaker screen board. Installed as KlipperScreen/panels/network.py (replaces the stock
# NetworkManager panel, which cannot work here: the board uses wpa_supplicant + dhcpcd, as WonderMaker set it up).
# It only talks to wpa_cli (the user t13dp is in the netdev group). Nothing is saved until a connection works.

import logging
import subprocess

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk, Pango  # noqa: E402

from ks_includes.screen_panel import ScreenPanel  # noqa: E402

try:
    from panels import zr_logic as L  # noqa: E402
except ImportError:
    import zr_logic as L  # noqa: E402

IFACE = "wlan0"


def wpa(*args, timeout=6):
    try:
        r = subprocess.run(["wpa_cli", "-i", IFACE] + list(args), capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except (OSError, subprocess.SubprocessError) as e:
        logging.warning("wpa_cli %s failed: %s", args, e)
        return ""


class Panel(ScreenPanel):
    def __init__(self, screen, title):
        super().__init__(screen, title or "Wi-Fi")
        self.root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.content.add(self.root)
        self.timer = None
        self.nets = []
        self.show_list()

    def _clear(self):
        if self.timer:
            GLib.source_remove(self.timer)
            self.timer = None
        try:
            self._screen.remove_keyboard()
        except Exception:
            pass
        for c in self.root.get_children():
            self.root.remove(c)

    def _label(self, text, wrap=True):
        lbl = Gtk.Label(label=text)
        lbl.set_xalign(0)
        lbl.set_line_wrap(wrap)
        return lbl

    def _status_text(self):
        st = L.wifi_parse_status(wpa("status"))
        if st.get("wpa_state") == "COMPLETED":
            return "Connected to %s\nAddress: %s" % (st.get("ssid", "?"), st.get("ip_address", "no address yet"))
        return "Not connected (%s)" % st.get("wpa_state", "wpa_supplicant not running")

    def show_list(self, scan=True):
        self._clear()
        self.root.pack_start(self._label(self._status_text()), False, False, 0)
        row = Gtk.Box(spacing=8)
        btn = self._gtk.Button("refresh", "Scan again", "color1")
        btn.connect("clicked", lambda _w: self.show_list(True))
        row.pack_start(btn, False, False, 0)
        self.root.pack_start(row, False, False, 0)
        self.listbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        sw = Gtk.ScrolledWindow()
        sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        sw.add(self.listbox)
        self.root.pack_start(sw, True, True, 0)
        if scan:
            self.listbox.pack_start(self._label("Scanning..."), False, False, 0)
            wpa("scan")
            self.timer = GLib.timeout_add_seconds(4, self._fill)
        else:
            self._fill()
        self.root.show_all()

    def _fill(self):
        self.timer = None
        for c in self.listbox.get_children():
            self.listbox.remove(c)
        self.nets = L.wifi_parse_scan(wpa("scan_results"))
        if not self.nets:
            self.listbox.pack_start(self._label("No networks found. Try Scan again."), False, False, 0)
        for n in self.nets[:12]:
            text = "%s   %s%s" % (n["ssid"], "|" * L.wifi_signal_bars(n["signal"]), "  (password)" if n["secured"] else "")
            b = Gtk.Button(label=text)
            b.get_child().set_ellipsize(Pango.EllipsizeMode.END)
            b.connect("clicked", lambda _w, net=n: self.pick(net))
            self.listbox.pack_start(b, False, False, 0)
        self.listbox.show_all()
        return False

    def pick(self, net):
        known = L.wifi_parse_networks(wpa("list_networks"))
        if net["ssid"] in known:
            self.connect(net, None, known[net["ssid"]])
        elif not net["secured"]:
            self.connect(net, None, None)
        else:
            self.ask_password(net)

    def ask_password(self, net):
        self._clear()
        self.root.pack_start(self._label("Password for %s (8 to 63 characters)" % net["ssid"]), False, False, 0)
        entry = Gtk.Entry()
        entry.set_visibility(True)
        self.root.pack_start(entry, False, False, 0)
        row = Gtk.Box(spacing=8)
        ok = self._gtk.Button("complete", "Connect", "color3")
        ok.connect("clicked", lambda _w: self._try(net, entry.get_text()))
        back = self._gtk.Button("cancel", "Cancel", "color2")
        back.connect("clicked", lambda _w: self.show_list(False))
        row.pack_start(ok, True, True, 0)
        row.pack_start(back, True, True, 0)
        self.root.pack_start(row, False, False, 0)
        self.root.show_all()
        for ev in ("button-press-event", "touch-event"):   # same as KlipperScreen's own panels
            entry.connect(ev, self._screen.show_keyboard)
        GLib.timeout_add(400, self._open_keyboard, entry)

    def _open_keyboard(self, entry):
        try:
            entry.grab_focus()
            self._screen.show_keyboard(entry=entry)
        except Exception:
            logging.exception("could not open the on-screen keyboard")
        return False

    def _try(self, net, pw):
        if not L.wifi_password_ok(pw):
            self._screen.show_popup_message("The password must be 8 to 63 characters.")
            return
        self.connect(net, pw, None)

    def connect(self, net, pw, known_id):
        self._clear()
        self.root.pack_start(self._label("Connecting to %s ..." % net["ssid"]), False, False, 0)
        self.root.show_all()
        self.prev = L.wifi_parse_status(wpa("status")).get("id")
        self.new_id = known_id
        self.created = False
        if known_id is None:
            nid = wpa("add_network")
            if not nid.isdigit():
                self._screen.show_popup_message("Could not add the network.")
                return self.show_list(False)
            self.new_id, self.created = int(nid), True
            wpa("set_network", nid, "ssid", '"%s"' % net["ssid"])
            if pw is None:
                wpa("set_network", nid, "key_mgmt", "NONE")
            else:
                wpa("set_network", nid, "psk", '"%s"' % pw)
        wpa("select_network", str(self.new_id))
        self.tries = 0
        self.timer = GLib.timeout_add_seconds(1, self._poll, net)

    def _poll(self, net):
        self.tries += 1
        st = L.wifi_parse_status(wpa("status"))
        if st.get("wpa_state") == "COMPLETED" and st.get("ssid") == net["ssid"]:
            wpa("enable_network", "all")
            wpa("save_config")
            self.timer = None
            self.show_list(False)
            return False
        if self.tries >= 25:
            if self.created:
                wpa("remove_network", str(self.new_id))
            if self.prev and self.prev.isdigit():
                wpa("select_network", self.prev)
            wpa("enable_network", "all")
            self.timer = None
            self._screen.show_popup_message("Could not connect to %s. The previous network was restored." % net["ssid"])
            self.show_list(False)
            return False
        return True
