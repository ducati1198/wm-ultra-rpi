#!/usr/bin/env python3
# Rescue window for KlipperScreen on the WonderMaker screen board.            NOT YET TESTED ON HARDWARE
# Started by wm-screen-rescue (own X server). Every button runs "wm-screen-rescue act NAME".
#   --reason failed|manual|usb     why the window is open
#   --test                         test mode: buttons only say what they would do (sets WM_RESCUE_DRY=1)
#   --script PATH                  the wm-screen-rescue script (default /usr/local/sbin/wm-screen-rescue)
import argparse
import os
import subprocess
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

CSS = b"""
window, .page { background: #141a1f; }
label { color: #ffffff; font-size: 17px; }
.title { font-size: 25px; font-weight: bold; }
.small { font-size: 14px; color: #aab4bd; }
.mono { font-family: monospace; font-size: 13px; }
button { min-height: 62px; padding: 4px 14px; border-radius: 8px; background: #2c3640; color: #ffffff; font-size: 19px; border: none; }
button.go { background: #1f7a3d; }
button.warn { background: #a3591a; }
button.stop { background: #a32626; }
button.plain { min-height: 52px; background: #2c3640; font-size: 17px; }
"""


class Rescue(Gtk.Window):
    def __init__(self, args):
        super().__init__(title="WonderMaker screen rescue")
        self.args = args
        self.env = dict(os.environ)
        if args.test:
            self.env["WM_RESCUE_DRY"] = "1"
        self.fullscreen() if not args.test else self.set_default_size(800, 480)
        prov = Gtk.CssProvider(); prov.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(self.get_screen(), prov, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self.stack = Gtk.Stack()
        self.add(self.stack)
        self.build_main(); self.build_more(); self.build_confirm(); self.build_text()
        self.connect("destroy", Gtk.main_quit)
        self.show_all()

    # ---- helpers
    def act(self, name, *extra):
        cmd = [self.args.script, "act", name, *extra]
        try:
            out = subprocess.run(cmd, env=self.env, capture_output=True, text=True, timeout=60)
            return (out.stdout + out.stderr).strip()
        except (OSError, subprocess.SubprocessError) as e:
            return "Could not run %s: %s" % (name, e)

    def page(self, name):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.get_style_context().add_class("page"); box.set_border_width(14)
        self.stack.add_named(box, name)
        return box

    def label(self, text, cls=None, wrap=True):
        lb = Gtk.Label(label=text); lb.set_xalign(0); lb.set_line_wrap(wrap)
        if cls:
            lb.get_style_context().add_class(cls)
        return lb

    def button(self, text, cb, cls=None):
        b = Gtk.Button(label=text); b.connect("clicked", lambda _w: cb())
        if cls:
            b.get_style_context().add_class(cls)
        return b

    # ---- main page
    def build_main(self):
        p = self.page("main")
        p.pack_start(self.label("KlipperScreen needs help", "title"), False, False, 0)
        self.reason = self.label(self.act("reason", self.args.reason), "small")
        p.pack_start(self.reason, False, False, 0)
        if self.args.test:
            p.pack_start(self.label("TEST MODE: buttons only show what they would do.", "small"), False, False, 0)
        grid = Gtk.Grid(column_spacing=10, row_spacing=10, column_homogeneous=True, row_homogeneous=True)
        grid.attach(self.button("Restart KlipperScreen", lambda: self.run_and_show("restart-ks", "Restarting KlipperScreen..."), "go"), 0, 0, 1, 1)
        grid.attach(self.button("Factory restore", lambda: self.stack.set_visible_child_name("confirm"), "warn"), 1, 0, 1, 1)
        grid.attach(self.button("Reboot board", lambda: self.run_and_show("reboot", "Rebooting..."), "plain"), 0, 1, 1, 1)
        grid.attach(self.button("More...", lambda: self.stack.set_visible_child_name("more"), "plain"), 1, 1, 1, 1)
        p.pack_start(grid, True, True, 0)
        self.status = self.label("", "small"); p.pack_start(self.status, False, False, 0)

    def run_and_show(self, name, busy):
        self.status.set_text(busy)
        GLib.idle_add(lambda: (self.show_text(name.replace("-", " ").title(), self.act(name)), False)[1])

    # ---- more page
    def build_more(self):
        p = self.page("more")
        p.pack_start(self.label("More", "title"), False, False, 0)
        grid = Gtk.Grid(column_spacing=10, row_spacing=10, column_homogeneous=True, row_homogeneous=True)
        items = [("Show error details", lambda: self.show_text("Error details", self.act("details"))),
                 ("Network status", lambda: self.show_text("Network status", self.act("net"))),
                 ("Reset KlipperScreen settings", lambda: self.show_text("Reset settings", self.act("reset-settings"))),
                 ("Reinstall KlipperScreen files", lambda: self.show_text("Reinstall files", self.act("reinstall-files")))]
        for i, (t, cb) in enumerate(items):
            grid.attach(self.button(t, cb, "plain"), i % 2, i // 2, 1, 1)
        p.pack_start(grid, True, True, 0)
        p.pack_start(self.button("Back", lambda: self.stack.set_visible_child_name("main"), "plain"), False, False, 0)

    # ---- confirm page for the factory restore
    def build_confirm(self):
        p = self.page("confirm")
        p.pack_start(self.label("Go back to the WonderMaker software?", "title"), False, False, 0)
        p.pack_start(self.label("KlipperScreen is removed, the factory screen app and its services are turned back on, and the board "
                                "reboots. Your KlipperScreen settings and the Pi address are saved first, so you can install KlipperScreen "
                                "again later with the same command."), False, False, 0)
        p.pack_start(self.label("", "small"), True, True, 0)
        row = Gtk.Box(spacing=10, homogeneous=True)
        row.pack_start(self.button("Cancel", lambda: self.stack.set_visible_child_name("main"), "plain"), True, True, 0)
        row.pack_start(self.button("Yes, restore factory mode", lambda: self.run_and_show("factory", "Restoring..."), "stop"), True, True, 0)
        p.pack_start(row, False, False, 0)

    # ---- text page (details, network, results)
    def build_text(self):
        p = self.page("text")
        self.text_title = self.label("", "title"); p.pack_start(self.text_title, False, False, 0)
        sw = Gtk.ScrolledWindow(); sw.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.text_body = self.label("", "mono"); self.text_body.set_selectable(False); self.text_body.set_yalign(0); self.text_body.set_valign(Gtk.Align.START)
        sw.add(self.text_body); p.pack_start(sw, True, True, 0)
        p.pack_start(self.button("Back", lambda: self.stack.set_visible_child_name("main"), "plain"), False, False, 0)

    def show_text(self, title, body):
        self.text_title.set_text(title); self.text_body.set_text(body or "(nothing to show)")
        self.stack.set_visible_child_name("text")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--reason", default="failed"); ap.add_argument("--test", action="store_true")
    ap.add_argument("--script", default="/usr/local/sbin/wm-screen-rescue")
    ap.add_argument("--page", default="main", help="test only: first page to show (main, more, confirm)")
    args = ap.parse_args()
    w = Rescue(args)
    w.stack.set_visible_child_name(args.page)
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
