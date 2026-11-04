#!/usr/bin/env python3
# Rescue window for KlipperScreen on the WonderMaker screen board.            NOT YET TESTED ON HARDWARE
# Started by wm-screen-rescue (own X server). Every button runs "wm-screen-rescue act NAME".
#   --reason failed|manual|usb     why the window is open
#   --test                         test mode: buttons only say what they would do (sets WM_RESCUE_DRY=1)
#   --script PATH                  the wm-screen-rescue script (default /usr/local/sbin/wm-screen-rescue)
import argparse
import os
import re
import subprocess
import sys
import threading

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
progressbar trough { min-height: 30px; border-radius: 8px; background: #2c3640; border: none; }
progressbar progress { min-height: 30px; border-radius: 8px; background: #2f7bf6; border: none; }
progressbar text { color: #ffffff; font-size: 16px; }
"""


STEP_RE = re.compile(r"^STEP (\d+)/(\d+) (.*)$")


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
        self.build_main(); self.build_more(); self.build_ask(); self.build_progress(); self.build_text()
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
        grid.attach(self.button("Restart KlipperScreen", lambda: self.ask(
            "Restart KlipperScreen?", "This window closes and KlipperScreen starts again.",
            "Yes, restart", lambda: self.run_and_show("restart-ks", "Restarting KlipperScreen..."), "go"), "go"), 0, 0, 1, 1)
        grid.attach(self.button("Factory restore", lambda: self.ask(
            "Go back to the WonderMaker software?",
            "KlipperScreen is removed, the factory screen app and its services are turned back on, and the board "
            "reboots. Your KlipperScreen settings and the Pi address are saved first, so you can install KlipperScreen "
            "again later with the same command.",
            "Yes, restore factory mode", lambda: self.run_with_progress("factory", "Factory restore", True), "stop"), "warn"), 1, 0, 1, 1)
        grid.attach(self.button("Reboot board", lambda: self.ask(
            "Reboot the board?", "The board restarts. KlipperScreen starts again by itself if it can.",
            "Yes, reboot", lambda: self.run_and_show("reboot", "Rebooting..."), "stop"), "plain"), 0, 1, 1, 1)
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
                 ("Reset KlipperScreen settings", lambda: self.ask(
                     "Reset KlipperScreen settings?",
                     "KlipperScreen goes back to its default settings. The Pi address is kept and your current settings are saved first.",
                     "Yes, reset settings", lambda: self.run_with_progress("reset-settings", "Reset KlipperScreen settings", False), "warn")),
                 ("Reinstall KlipperScreen files", lambda: self.ask(
                     "Reinstall the KlipperScreen files?",
                     "The KlipperScreen program files are replaced by the copy saved at install time. Your settings and the Pi address are kept.",
                     "Yes, reinstall", lambda: self.run_with_progress("reinstall-files", "Reinstall KlipperScreen files", False), "warn"))]
        for i, (t, cb) in enumerate(items):
            grid.attach(self.button(t, cb, "plain"), i % 2, i // 2, 1, 1)
        p.pack_start(grid, True, True, 0)
        p.pack_start(self.button("Back", lambda: self.stack.set_visible_child_name("main"), "plain"), False, False, 0)

    # ---- one confirmation page for every action: what will happen, Cancel / Yes
    def build_ask(self):
        p = self.page("ask")
        self.ask_title = self.label("", "title"); p.pack_start(self.ask_title, False, False, 0)
        self.ask_text = self.label(""); p.pack_start(self.ask_text, False, False, 0)
        p.pack_start(self.label("", "small"), True, True, 0)
        row = Gtk.Box(spacing=10, homogeneous=True)
        row.pack_start(self.button("Cancel", self.ask_cancel, "plain"), True, True, 0)
        self.ask_yes = self.button("Yes", lambda: self.ask_go(), "go")
        row.pack_start(self.ask_yes, True, True, 0)
        p.pack_start(row, False, False, 0)
        self.ask_cb = None; self.ask_back = "main"

    def ask(self, title, text, yes_label, cb, cls="go"):
        self.ask_back = self.stack.get_visible_child_name() or "main"
        self.ask_title.set_text(title); self.ask_text.set_text(text)
        self.ask_yes.set_label(yes_label)
        ctx = self.ask_yes.get_style_context()
        for c in ("go", "warn", "stop"):
            ctx.remove_class(c)
        ctx.add_class(cls)
        self.ask_cb = cb
        self.stack.set_visible_child_name("ask")

    def ask_cancel(self):
        self.stack.set_visible_child_name(self.ask_back)

    def ask_go(self):
        cb, self.ask_cb = self.ask_cb, None
        if cb:
            cb()

    # ---- progress page: real steps ("STEP 2/4 text" lines from the script), then an estimate while the board reboots
    def build_progress(self):
        p = self.page("progress")
        self.prog_title = self.label("", "title"); p.pack_start(self.prog_title, False, False, 0)
        p.pack_start(self.label("", "small"), True, True, 0)
        self.prog_step = self.label("Starting...")
        p.pack_start(self.prog_step, False, False, 0)
        self.prog_bar = Gtk.ProgressBar(); self.prog_bar.set_show_text(True); self.prog_bar.set_text("0 %")
        p.pack_start(self.prog_bar, False, False, 0)
        self.prog_note = self.label("Please wait. Do not switch the board off.", "small")
        p.pack_start(self.prog_note, False, False, 6)
        p.pack_start(self.label("", "small"), True, True, 0)
        self.prog_timer = None

    def set_progress(self, frac, text=None):
        frac = max(0.0, min(1.0, frac))
        self.prog_bar.set_fraction(frac); self.prog_bar.set_text("%d %%" % round(frac * 100))
        if text:
            self.prog_step.set_text(text)

    def run_with_progress(self, name, title, reboots):
        """Runs the action in a thread so the bar keeps moving. `reboots`: the board restarts at the end (the window is
        closed by the restore itself), so after the last real step the bar fills slowly as an estimate."""
        self.prog_title.set_text(title)
        self.prog_note.set_text("Please wait. Do not switch the board off.")
        self.set_progress(0.0, "Starting...")
        self.stack.set_visible_child_name("progress")
        out = []

        def worker():
            rc = 1
            try:
                proc = subprocess.Popen([self.args.script, "act", name], env=self.env, stdout=subprocess.PIPE,
                                        stderr=subprocess.STDOUT, text=True)
                for line in proc.stdout:
                    m = STEP_RE.match(line.strip())
                    if m:
                        i, n, txt = int(m.group(1)), int(m.group(2)), m.group(3)
                        GLib.idle_add(self.set_progress, (i - 1) / float(n), "Step %d of %d: %s" % (i, n, txt))
                    else:
                        out.append(line.rstrip())
                rc = proc.wait()
            except (OSError, subprocess.SubprocessError) as e:
                out.append("Could not run %s: %s" % (name, e))
            GLib.idle_add(self.progress_done, title, rc, "\n".join(out).strip(), reboots)

        threading.Thread(target=worker, daemon=True).start()

    def progress_done(self, title, rc, text, reboots):
        if rc != 0:
            self.show_text(title + " failed", text or "The action failed. Details: /var/log/wm-screen-rescue.log")
            return False
        if reboots:
            self.prog_note.set_text("Done on this side. The board restarts by itself; the bar is an estimate.")
            self.set_progress(0.75, "Restoring the factory software...")
            self.prog_timer = GLib.timeout_add(1000, self.estimate_tick)
        else:
            self.set_progress(1.0, "Done. KlipperScreen is starting...")
        return False

    def estimate_tick(self):
        f = self.prog_bar.get_fraction() + 0.006
        self.set_progress(min(f, 0.98))
        return f < 0.98

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
    ap.add_argument("--page", default="main", help="test only: first page to show (main, more, ask, progress)")
    args = ap.parse_args()
    w = Rescue(args)
    w.stack.set_visible_child_name(args.page)
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
