#!/usr/bin/env python3
"""RawOS graphical installer - a GTK wizard (Welcome / Location / Keyboard /
Disk / Account / Summary / Install / Finish) that drives the proven rawos-installer
engine. Runs as root (launched via pkexec by the Install RawOS launcher)."""
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import threading

import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, GLib, Gdk  # noqa: E402

TN_BG = "#1a1b26"; TN_BG2 = "#16161e"; TN_FG = "#c0caf5"
TN_ACCENT = "#7aa2f7"; TN_MUTE = "#565f89"; TN_RED = "#f7768e"; TN_GREEN = "#9ece6a"
ENGINE = "/usr/local/bin/rawos-installer"
STEPS = ["Welcome", "Location", "Keyboard", "Disk", "Account", "Summary", "Install", "Finish"]

KEYMAPS = ["us", "gb", "de", "fr", "es", "it", "ru", "rs", "pl", "pt", "br",
           "tr", "se", "no", "fi", "dk", "nl", "cz", "hu", "gr", "jp", "ua"]

# Engine "==> " markers -> (progress fraction it starts at, friendly label).
# The copy phase spans 0.15 .. 0.86 and is driven live by rsync's percentage.
PHASES = [
    ("Partitioning", 0.05, "Partitioning the disk"),
    ("Formatting",   0.10, "Formatting partitions"),
    ("Copying",      0.15, "Copying RawOS to disk"),
    ("Writing fstab", 0.86, "Writing filesystem table"),
    ("Bootloader",   0.90, "Installing the bootloader"),
    ("Cleaning up",  0.97, "Finishing up"),
]
COPY_LO, COPY_HI = 0.15, 0.86

# Strip terminal escape sequences so the log never shows raw "[1;34m" garbage.
ANSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")


def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True,
                                       stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""


def list_disks():
    res = []
    for line in sh("lsblk -dpno NAME,SIZE,MODEL").splitlines():
        parts = line.split(None, 2)
        if not parts:
            continue
        name = parts[0]
        if "/dev/loop" in name or "/dev/sr" in name or "/dev/zram" in name:
            continue
        size = parts[1] if len(parts) > 1 else ""
        model = parts[2].strip() if len(parts) > 2 else "Disk"
        res.append((name, f"{name}   {size}   {model}"))
    return res


def list_timezones():
    tz = sh("timedatectl list-timezones").splitlines()
    if not tz:
        tz = ["UTC", "America/New_York", "America/Los_Angeles", "Europe/London",
              "Europe/Belgrade", "Europe/Berlin", "Europe/Paris", "Asia/Tokyo"]
    return tz


def current_tz():
    tz = sh("timedatectl show -p Timezone --value")
    if not tz:
        try:
            tz = open("/etc/timezone").read().strip()
        except Exception:
            tz = ""
    return tz or "UTC"


def current_keymap():
    # try the live X session first, then localectl
    km = sh("setxkbmap -query 2>/dev/null | awk '/^layout/{print $2}'")
    if not km:
        km = sh("localectl status 2>/dev/null | awk -F: '/X11 Layout/{print $2}' | tr -d ' '")
    km = (km or "us").split(",")[0]
    return km or "us"


class Installer(Gtk.Window):
    def __init__(self):
        super().__init__(title="RawOS Installer")
        self.set_default_size(960, 640)
        self.set_position(Gtk.WindowPosition.CENTER)
        self.connect("destroy", Gtk.main_quit)
        self.idx = 0
        self.installing = False
        self.done_ok = False
        self.phase = None
        self.ok = False

        css = Gtk.CssProvider()
        css.load_from_data((f"""
          window {{ background: {TN_BG2}; }}
          .sidebar {{ background: {TN_BG}; }}
          .step {{ color: {TN_MUTE}; padding: 12px 18px; font-size: 14px; }}
          .step.active {{ color: {TN_FG}; background: alpha({TN_ACCENT}, 0.16);
                          border-left: 3px solid {TN_ACCENT}; font-weight: bold; }}
          .step.done {{ color: {TN_GREEN}; }}
          .h1 {{ color: {TN_FG}; font-size: 22px; font-weight: bold; }}
          .muted {{ color: {TN_MUTE}; }}
          .fg {{ color: {TN_FG}; }}
          .warn {{ color: {TN_RED}; font-weight: bold; }}
          .ok {{ color: {TN_GREEN}; font-weight: bold; }}
          entry {{ background: {TN_BG}; color: {TN_FG}; border-radius: 6px;
                   padding: 6px 8px; }}
          textview, textview text {{ background:{TN_BG}; color:{TN_FG};
                                     font-family: monospace; font-size: 12px; }}
          progressbar text {{ color: {TN_FG}; }}
          progressbar progress {{ background-color: {TN_ACCENT}; }}
        """).encode())
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        self.add(outer)
        body = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL)
        outer.pack_start(body, True, True, 0)

        # sidebar
        side = Gtk.Box(orientation=Gtk.Orientation.VERTICAL)
        side.get_style_context().add_class("sidebar")
        side.set_size_request(220, -1)
        logo = Gtk.Label(label="Raw<span foreground='%s'>OS</span>" % TN_ACCENT)
        logo.set_use_markup(True)
        logo.get_style_context().add_class("h1")
        logo.set_margin_top(22); logo.set_margin_bottom(18)
        side.pack_start(logo, False, False, 0)
        self.step_lbls = []
        for s in STEPS:
            lbl = Gtk.Label(label=s, xalign=0)
            lbl.get_style_context().add_class("step")
            side.pack_start(lbl, False, False, 0)
            self.step_lbls.append(lbl)
        body.pack_start(side, False, False, 0)

        # content stack
        self.stack = Gtk.Stack()
        self.stack.set_border_width(28)
        body.pack_start(self.stack, True, True, 0)
        self._build_pages()

        # nav
        nav = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        nav.set_border_width(12)
        self.btn_quit = Gtk.Button(label="Quit")
        self.btn_quit.connect("clicked", lambda *_: self.close())
        self.btn_back = Gtk.Button(label="Back")
        self.btn_back.connect("clicked", self.on_back)
        self.btn_next = Gtk.Button(label="Next")
        self.btn_next.get_style_context().add_class("suggested-action")
        self.btn_next.connect("clicked", self.on_next)
        nav.pack_start(self.btn_quit, False, False, 0)
        nav.pack_end(self.btn_next, False, False, 0)
        nav.pack_end(self.btn_back, False, False, 0)
        outer.pack_start(nav, False, False, 0)

        self.show_all()
        self._refresh()

    # ---- pages ----
    def _page(self, title, subtitle=None):
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        h = Gtk.Label(label=title, xalign=0); h.get_style_context().add_class("h1")
        box.pack_start(h, False, False, 0)
        if subtitle:
            s = Gtk.Label(label=subtitle, xalign=0, wrap=True)
            s.get_style_context().add_class("muted")
            box.pack_start(s, False, False, 0)
        return box

    def _searchable_combo(self, items):
        combo = Gtk.ComboBoxText.new_with_entry()
        for it in items:
            combo.append_text(it)
        store = Gtk.ListStore(str)
        for it in items:
            store.append([it])
        comp = Gtk.EntryCompletion()
        comp.set_model(store); comp.set_text_column(0)
        comp.set_inline_completion(True); comp.set_popup_completion(True)
        comp.set_minimum_key_length(1)
        combo.get_child().set_completion(comp)
        return combo

    def _build_pages(self):
        # Welcome
        p = self._page("Welcome to RawOS")
        t = Gtk.Label(xalign=0, wrap=True)
        t.set_markup("This installs <b>RawOS</b> - a curated malware reverse-engineering\n"
                     "workstation built around RawView.\n\n"
                     "Four quick questions (timezone, keyboard, disk, account) and it\n"
                     "installs to your disk. The whole thing takes a few minutes.")
        t.get_style_context().add_class("fg")
        p.pack_start(t, False, False, 0)
        self.stack.add_named(p, "Welcome")

        # Location: region -> city (two short lists instead of one 350-item wall),
        # both preselected from the live session so most people just click Next.
        p = self._page("Location", "Pick your region, then your city. Sets the timezone and clock.")
        self._tzmap = self._build_tz_map()
        regions = sorted(self._tzmap.keys())
        grid = Gtk.Grid(row_spacing=12, column_spacing=12)
        grid.attach(Gtk.Label(label="Region:", xalign=0), 0, 0, 1, 1)
        grid.attach(Gtk.Label(label="City:", xalign=0), 0, 1, 1, 1)
        self.region_combo = Gtk.ComboBoxText()
        for r in regions:
            self.region_combo.append_text(r)
        self.city_combo = Gtk.ComboBoxText()
        self.region_combo.set_hexpand(True); self.city_combo.set_hexpand(True)
        grid.attach(self.region_combo, 1, 0, 1, 1)
        grid.attach(self.city_combo, 1, 1, 1, 1)
        p.pack_start(grid, False, False, 0)
        self.tz_hint = Gtk.Label(xalign=0)
        self.tz_hint.get_style_context().add_class("muted")
        p.pack_start(self.tz_hint, False, False, 0)
        self._cur_cities = []
        self.region_combo.connect("changed", self._on_region_changed)
        self.city_combo.connect("changed", self._on_city_changed)
        # Preselect the live session's timezone (e.g. Europe/Belgrade -> Europe + Belgrade).
        cur = current_tz()
        cr, cc = (cur.split("/", 1) if "/" in cur else ("Other", cur))
        self.region_combo.set_active(regions.index(cr) if cr in regions else 0)
        for i, (_disp, full) in enumerate(self._cur_cities):
            if full == cur:
                self.city_combo.set_active(i)
                break
        self.stack.add_named(p, "Location")

        # Keyboard
        p = self._page("Keyboard", "Type to search or pick your layout.")
        km_list = list(KEYMAPS)
        curk = current_keymap()
        if curk not in km_list:
            km_list.insert(0, curk)
        self.kb_combo = self._searchable_combo(km_list)
        self.kb_combo.set_active(km_list.index(curk))
        self.kb_combo.get_child().connect("activate", self.on_next)
        p.pack_start(self.kb_combo, False, False, 0)
        self.stack.add_named(p, "Keyboard")

        # Disk
        p = self._page("Disk", "RawOS will erase this disk and install itself on it.")
        w = Gtk.Label(xalign=0)
        w.set_markup("Everything on the selected disk will be <b>permanently deleted</b>.")
        w.get_style_context().add_class("warn")
        p.pack_start(w, False, False, 0)
        p.pack_start(Gtk.Label(label="Target disk:", xalign=0), False, False, 0)
        self.disk_combo = Gtk.ComboBoxText()
        self._disks = list_disks()
        for _, label in self._disks:
            self.disk_combo.append_text(label)
        if self._disks:
            self.disk_combo.set_active(0)
        else:
            no = Gtk.Label(xalign=0)
            no.set_markup("No disks found. Close this and check the VM/disk setup.")
            no.get_style_context().add_class("warn")
            p.pack_start(no, False, False, 0)
        p.pack_start(self.disk_combo, False, False, 0)
        self.stack.add_named(p, "Disk")

        # Account
        p = self._page("Your account")
        grid = Gtk.Grid(row_spacing=10, column_spacing=12)
        self.e_user = Gtk.Entry(); self.e_host = Gtk.Entry(text="rawos")
        self.e_pw = Gtk.Entry(visibility=False)
        self.e_pw2 = Gtk.Entry(visibility=False)
        self.e_pw.set_icon_from_icon_name(Gtk.EntryIconPosition.SECONDARY, "view-reveal-symbolic")
        self.e_pw.set_icon_activatable(Gtk.EntryIconPosition.SECONDARY, True)
        self.e_pw.set_icon_tooltip_text(Gtk.EntryIconPosition.SECONDARY, "Show password")
        self.e_pw.connect("icon-press", self._toggle_pw)
        rows = [("Username", self.e_user), ("Password", self.e_pw),
                ("Confirm password", self.e_pw2), ("Computer name", self.e_host)]
        for i, (lab, ent) in enumerate(rows):
            grid.attach(Gtk.Label(label=lab, xalign=0), 0, i, 1, 1)
            ent.set_hexpand(True)
            ent.connect("activate", self.on_next)
            ent.connect("changed", lambda *_: self.acc_err.set_text(""))
            grid.attach(ent, 1, i, 1, 1)
        p.pack_start(grid, False, False, 0)
        self.acc_err = Gtk.Label(xalign=0); self.acc_err.get_style_context().add_class("warn")
        p.pack_start(self.acc_err, False, False, 0)
        self.stack.add_named(p, "Account")

        # Summary
        p = self._page("Summary")
        self.summary_lbl = Gtk.Label(xalign=0)
        self.summary_lbl.get_style_context().add_class("fg")
        p.pack_start(self.summary_lbl, False, False, 0)
        self.stack.add_named(p, "Summary")

        # Install: clean status + progress up top (Calamares-like), raw log tucked
        # into a collapsible Details pane so it isn't a wall of terminal text.
        p = self._page("Installing RawOS", "This takes a few minutes. Do not power off.")
        self.status_lbl = Gtk.Label(xalign=0, label="Preparing")
        self.status_lbl.get_style_context().add_class("fg")
        p.pack_start(self.status_lbl, False, False, 0)
        self.progress = Gtk.ProgressBar(); self.progress.set_show_text(True)
        self.progress.set_text("Preparing")
        p.pack_start(self.progress, False, False, 0)
        exp = Gtk.Expander(label="Details")
        sw = Gtk.ScrolledWindow(); sw.set_vexpand(True); sw.set_min_content_height(240)
        self.logview = Gtk.TextView(editable=False, cursor_visible=False)
        self.logview.set_wrap_mode(Gtk.WrapMode.WORD_CHAR)
        sw.add(self.logview)
        exp.add(sw)
        p.pack_start(exp, True, True, 0)
        self.stack.add_named(p, "Install")

        # Finish
        p = self._page("Done")
        self.finish_lbl = Gtk.Label(xalign=0)
        self.finish_lbl.get_style_context().add_class("ok")
        p.pack_start(self.finish_lbl, False, False, 0)
        self.stack.add_named(p, "Finish")

    def _build_tz_map(self):
        """Group timezones by region -> list of (display_city, full_zone)."""
        regions = {}
        for tz in list_timezones():
            r, c = (tz.split("/", 1) if "/" in tz else ("Other", tz))
            regions.setdefault(r, []).append((c.replace("_", " "), tz))
        for r in regions:
            regions[r].sort(key=lambda x: x[0])
        return regions

    def _on_region_changed(self, combo):
        r = combo.get_active_text()
        self.city_combo.remove_all()
        self._cur_cities = self._tzmap.get(r, [])
        for disp, _full in self._cur_cities:
            self.city_combo.append_text(disp)
        if self._cur_cities:
            self.city_combo.set_active(0)

    def _on_city_changed(self, combo):
        self.tz_hint.set_text("Timezone: " + (self._selected_tz() or ""))

    def _selected_tz(self):
        ci = self.city_combo.get_active()
        if self._cur_cities and 0 <= ci < len(self._cur_cities):
            return self._cur_cities[ci][1]
        return "UTC"

    def _toggle_pw(self, entry, pos, event):
        vis = not entry.get_visibility()
        self.e_pw.set_visibility(vis)
        self.e_pw2.set_visibility(vis)
        entry.set_icon_from_icon_name(
            Gtk.EntryIconPosition.SECONDARY,
            "view-conceal-symbolic" if vis else "view-reveal-symbolic")

    # ---- navigation ----
    def _refresh(self):
        name = STEPS[self.idx]
        self.stack.set_visible_child_name(name)
        for i, lbl in enumerate(self.step_lbls):
            ctx = lbl.get_style_context()
            ctx.remove_class("active"); ctx.remove_class("done")
            if i < self.idx:
                ctx.add_class("done")
            elif i == self.idx:
                ctx.add_class("active")
        self.btn_back.set_sensitive(self.idx > 0 and not self.installing and name != "Finish")
        if name == "Summary":
            self.btn_next.set_label("Install")
            self._fill_summary()
        elif name == "Install":
            self.btn_next.set_label("Next")
            self.btn_next.set_sensitive(False)
        elif name == "Finish":
            self.btn_next.set_label("Reboot")
            self.btn_next.set_sensitive(True)
            self.btn_back.set_sensitive(False)
        else:
            self.btn_next.set_label("Next")
            self.btn_next.set_sensitive(True)

    def _fill_summary(self):
        disk = self._disks[self.disk_combo.get_active()][0] if self._disks else "?"
        self.cfg = {
            "disk": disk,
            "tz": self._selected_tz(),
            "keymap": self.kb_combo.get_active_text() or "us",
            "user": self.e_user.get_text().strip(),
            "host": self.e_host.get_text().strip() or "rawos",
            "pw": self.e_pw.get_text(),
        }
        self.summary_lbl.set_markup(
            "RawOS will be installed with these settings:\n\n"
            f"  Target disk:  <b>{self.cfg['disk']}</b>  (will be ERASED)\n"
            f"  Timezone:     {self.cfg['tz']}\n"
            f"  Keyboard:     {self.cfg['keymap']}\n"
            f"  Username:     {self.cfg['user']}\n"
            f"  Computer:     {self.cfg['host']}\n\n"
            "Click <b>Install</b> to begin.")

    def on_back(self, *_):
        if self.idx > 0 and not self.installing:
            self.idx -= 1
            self._refresh()

    def on_next(self, *_):
        name = STEPS[self.idx]
        if name == "Account" and not self._validate_account():
            return
        if name == "Disk" and not self._disks:
            return
        if name == "Summary":
            self.idx += 1
            self._refresh()
            self._start_install()
            return
        if name == "Finish":
            subprocess.Popen(["systemctl", "reboot"])
            return
        if name == "Install":
            return
        if self.idx < len(STEPS) - 1:
            self.idx += 1
            self._refresh()

    def _validate_account(self):
        u = self.e_user.get_text().strip()
        p1, p2 = self.e_pw.get_text(), self.e_pw2.get_text()
        if not u:
            self.acc_err.set_text("Username is required."); return False
        if not re.match(r"^[a-z_][a-z0-9_-]*$", u):
            self.acc_err.set_text("Username must be lowercase letters, digits, - or _."); return False
        if not p1:
            self.acc_err.set_text("Password is required."); return False
        if p1 != p2:
            self.acc_err.set_text("Passwords do not match."); return False
        self.acc_err.set_text("")
        return True

    # ---- install ----
    def _log(self, text):
        buf = self.logview.get_buffer()
        buf.insert(buf.get_end_iter(), text)
        self.logview.scroll_to_iter(buf.get_end_iter(), 0.0, False, 0, 0)

    def _set_progress(self, frac, label):
        self.progress.set_fraction(max(0.0, min(1.0, frac)))
        self.progress.set_text(label)
        if hasattr(self, "status_lbl"):
            self.status_lbl.set_text(label)

    def _write_cfg(self):
        """Write install settings to a private temp file the root engine sources.
        This carries the config across the pkexec/sudo boundary (which wipes env)
        without putting the password on a command line visible in `ps`."""
        fd, path = tempfile.mkstemp(prefix="rawos-install-", suffix=".env")
        with os.fdopen(fd, "w") as f:
            f.write("RAWOS_UNATTENDED=1\n")
            for k, v in (("RAWOS_DISK", self.cfg["disk"]),
                         ("RAWOS_USER", self.cfg["user"]),
                         ("RAWOS_PASS", self.cfg["pw"]),
                         ("RAWOS_HOSTNAME", self.cfg["host"]),
                         ("RAWOS_TZ", self.cfg["tz"]),
                         ("RAWOS_KEYMAP", self.cfg["keymap"])):
                f.write(f"{k}={shlex.quote(v)}\n")
        os.chmod(path, 0o600)
        return path

    def _start_install(self):
        self.installing = True
        self.ok = False
        self.phase = None
        self.btn_quit.set_sensitive(False)
        self._set_progress(0.02, "Preparing")
        cfgfile = self._write_cfg()
        threading.Thread(target=self._run, args=(cfgfile,), daemon=True).start()

    def _emit(self, seg):
        """Parse one output segment (split on \\r or \\n) for progress + logging."""
        seg = ANSI.sub("", seg).replace("\x1b", "")
        if "RAWOS_INSTALL_OK" in seg:
            self.ok = True
        if "==>" in seg:
            for key, frac, label in PHASES:
                if key in seg:
                    self.phase = key
                    GLib.idle_add(self._set_progress, frac, label)
                    break
            GLib.idle_add(self._log, seg.strip() + "\n")
            return
        # live rsync percentage during the copy phase (arrives on \r)
        m = re.search(r"(\d+)%", seg)
        if m and self.phase == "Copying":
            pct = int(m.group(1))
            frac = COPY_LO + (pct / 100.0) * (COPY_HI - COPY_LO)
            GLib.idle_add(self._set_progress, frac, f"Copying RawOS to disk   {pct}%")
            return
        if seg.strip():
            GLib.idle_add(self._log, seg.strip() + "\n")

    def _stream(self, cmd):
        """Run one command, stream its output (splitting on \\r and \\n so rsync's
        live percentage shows), and return its exit code (or None on launch error)."""
        try:
            proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, bufsize=0)
        except Exception as e:  # noqa: BLE001
            GLib.idle_add(self._log, f"\ncould not launch {cmd[0]}: {e}\n")
            return None
        fd = proc.stdout.fileno()
        buf = b""
        while True:
            try:
                chunk = os.read(fd, 4096)
            except OSError:
                break
            if not chunk:
                break
            buf += chunk
            while True:
                m = re.search(rb"[\r\n]", buf)
                if not m:
                    break
                seg = buf[:m.start()]
                buf = buf[m.end():]
                if seg:
                    self._emit(seg.decode("utf-8", "replace"))
        if buf:
            self._emit(buf.decode("utf-8", "replace"))
        proc.wait()
        return proc.returncode

    def _run(self, cfgfile):
        # Escalate only the engine (the GUI itself runs as the normal user).
        # Try pkexec first, fall back to passwordless sudo, then a direct run
        # (works if we somehow already are root).
        candidates = []
        if shutil.which("pkexec"):
            candidates.append(["pkexec", ENGINE, cfgfile])
        if shutil.which("sudo"):
            candidates.append(["sudo", "-n", ENGINE, cfgfile])
        candidates.append([ENGINE, cfgfile])
        ok = False
        try:
            for i, cmd in enumerate(candidates):
                self.ok = False
                self.phase = None
                rc = self._stream(cmd)
                if self.ok and rc == 0:
                    ok = True
                    break
                # Launch/auth failure with nothing installed: try the next method.
                if (rc is None or rc in (126, 127)) and i < len(candidates) - 1:
                    GLib.idle_add(self._log,
                                  "\n(that elevation method was unavailable, trying another)\n")
                    continue
                break
        finally:
            try:
                os.unlink(cfgfile)
            except OSError:
                pass
        GLib.idle_add(self._finish, ok)

    def _finish(self, ok):
        self.installing = False
        self.done_ok = ok
        if ok:
            self._set_progress(1.0, "Done")
            self.idx = STEPS.index("Finish")
            self.finish_lbl.set_markup(
                "RawOS is installed.\n\n"
                "Remove the installation medium and reboot into your new system.")
            self._refresh()
        else:
            self._set_progress(0.0, "Failed")
            self.btn_quit.set_sensitive(True)
            self.btn_back.set_sensitive(True)
            self._log("\nInstallation failed. Review the log above, go Back and retry.\n")


def main():
    # Runs as the normal user so the window always opens; the install step itself
    # escalates via pkexec/sudo (see _run). No need to be root to draw the UI.
    Installer()
    Gtk.main()


if __name__ == "__main__":
    main()
