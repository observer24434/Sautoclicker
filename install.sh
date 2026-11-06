#!/usr/bin/env bash
# ============================================================================
#  Sautoclicker - one-file installer for Linux (Wayland and X11)
#
#  Install:    sh install.sh
#  Uninstall:  sh install.sh --uninstall
#  One-liner:  curl -fsSL https://raw.githubusercontent.com/observer24434/Sautoclicker/main/install.sh | bash
#
#  The app and the setup steps are inside this file; the icon is cursor.png (same folder).
#  Do NOT run it with sudo; it asks for sudo itself when needed.
# ============================================================================
# allow "sh install.sh" as well as "bash install.sh"
if [ -z "$BASH_VERSION" ] && command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
REPO_RAW="https://raw.githubusercontent.com/observer24434/Sautoclicker/main"
APP_NAME="Sautoclicker"
APP_ID="sautoclicker"
INSTALL_DIR="$HOME/.local/share/$APP_ID"
ICON_DIR="$HOME/.local/share/icons/hicolor/512x512/apps"
DESKTOP_DIR="$HOME/.local/share/applications"
DESKTOP_FILE="$DESKTOP_DIR/$APP_ID.desktop"

say() { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWarning:\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Linux" ] || die "This installer is for Linux only."
[ "$(id -u)" = "0" ] && die "Please run this as your normal user, not root/sudo."

NO_SYSTEM=0
for a in "$@"; do
    case "$a" in
        --no-system) NO_SYSTEM=1 ;;
        --uninstall)
            say "Removing $APP_NAME"
            rm -rf "$INSTALL_DIR" "$DESKTOP_FILE" "$ICON_DIR/$APP_ID.png"
            command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
            say "Done. Your settings in ~/.config/$APP_ID were kept. (The uinput permission rule was left in place; remove /etc/udev/rules.d/99-uinput.rules yourself if you want.)"
            exit 0 ;;
    esac
done

# -------------------------------------------------- 1. system packages + uinput
if [ "$NO_SYSTEM" = "0" ]; then
    say "Installing dependencies (sudo password may be asked)"
    if command -v pacman >/dev/null; then
        sudo pacman -S --needed --noconfirm python tk libxtst
        sudo pacman -S --needed --noconfirm python-pynput || true
    elif command -v apt >/dev/null; then
        sudo apt update && sudo apt install -y python3 python3-tk libxtst6
        sudo apt install -y python3-pynput || true
    elif command -v dnf >/dev/null; then
        sudo dnf install -y python3 python3-tkinter libXtst
        sudo dnf install -y python3-pynput || true
    elif command -v zypper >/dev/null; then
        sudo zypper install -y python3 python3-tk libXtst6
        sudo zypper install -y python3-pynput || true
    else
        warn "Unknown package manager. Install manually: python3 and tkinter."
    fi

    say "Setting up /dev/uinput access (needed for the fastest clicking)"
    sudo modprobe uinput || true
    echo uinput | sudo tee /etc/modules-load.d/uinput.conf >/dev/null
    echo 'KERNEL=="uinput", GROUP="input", MODE="0660", TAG+="uaccess"' \
        | sudo tee /etc/udev/rules.d/99-uinput.rules >/dev/null
    sudo udevadm control --reload-rules || true
    sudo udevadm trigger || true
    if ! id -nG "$USER" | tr ' ' '\n' | grep -qx input; then
        sudo usermod -aG input "$USER" || warn "Could not add you to the 'input' group."
        NEED_RELOGIN=1
    fi
fi

# ----------------------------------------------------------- 2. write the app
PY=/usr/bin/python3
[ -x "$PY" ] || PY="$(command -v python3 || true)"
[ -n "$PY" ] || die "python3 not found."

say "Installing $APP_NAME to $INSTALL_DIR"
mkdir -p "$INSTALL_DIR" "$ICON_DIR" "$DESKTOP_DIR"

cat > "$INSTALL_DIR/$APP_ID.py" <<'PYEOF'
#!/usr/bin/env python3
"""Sautoclicker - fast auto clicker with a modern GUI for Linux, Windows and macOS.

Click methods (no subprocess per click, so they are very fast):
  Linux   : uinput (built in, works on Wayland AND X11) -> XTest (X11 only) -> ydotool/xdotool
  Windows : SendInput (built in, nothing to install)
  macOS   : Quartz CGEvent (built in, needs Accessibility permission)

Clicks happen at the current mouse pointer position.
Settings are saved automatically. The look follows the system dark / light setting.
Run with --check to print diagnostics.
"""
import ctypes
import ctypes.util
import errno
import json
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import traceback
import types

try:
    import tkinter as tk
    from tkinter import font as tkfont
    from tkinter import messagebox
except ImportError:
    _hint = {
        "win32": "Reinstall Python from python.org and keep 'tcl/tk and IDLE' ticked.",
        "darwin": "Install it with: brew install python-tk   (or use Python from python.org)",
    }.get(sys.platform, "Install it: sudo pacman -S tk   |   sudo apt install python3-tk   |   sudo dnf install python3-tkinter")
    sys.stderr.write("Sautoclicker needs Tk (tkinter), which is missing.\n" + _hint + "\n")
    sys.exit(1)

APP_NAME = "Sautoclicker"
HERE = os.path.dirname(os.path.abspath(__file__))
IS_WIN = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"

BUTTONS = {"Left": 1, "Middle": 2, "Right": 3}  # X11 numbering
DEFAULTS = {"interval": 50, "button": "Left", "count": 0, "delay": 3}


def config_dir():
    if IS_WIN:
        return os.path.join(os.environ.get("APPDATA") or os.path.expanduser("~"), APP_NAME)
    if IS_MAC:
        return os.path.join(os.path.expanduser("~/Library/Application Support"), APP_NAME)
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, APP_NAME.lower())


CONFIG_DIR = config_dir()
CONFIG_FILE = os.path.join(CONFIG_DIR, "settings.json")
LOG_FILE = os.path.join(CONFIG_DIR, "error.log")


def _p(*args):
    """print() that never fails (pythonw on Windows has no stdout)."""
    try:
        print(*args)
    except Exception:
        pass


def log_error(text):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 200000:
            os.remove(LOG_FILE)
        with open(LOG_FILE, "a", encoding="utf-8") as f:
            f.write(time.strftime("[%Y-%m-%d %H:%M:%S] ") + text.rstrip() + "\n")
    except Exception:
        pass


# ------------------------------------------------------------ saved settings
def load_settings():
    try:
        with open(CONFIG_FILE, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
    s = dict(DEFAULTS)
    if isinstance(data, dict):
        for k, v in data.items():
            if k in s and isinstance(v, type(DEFAULTS[k])) and not isinstance(v, bool):
                s[k] = v
    if s["button"] not in BUTTONS:
        s["button"] = "Left"
    return s


def save_settings(s):
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        tmp = CONFIG_FILE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(s, f, indent=2)
        os.replace(tmp, CONFIG_FILE)
    except Exception:
        pass


# ------------------------------------------------------- single instance lock
_LOCK = None


def acquire_single_instance():
    """Return a lock object, or None if another copy is already running."""
    global _LOCK
    try:
        os.makedirs(CONFIG_DIR, exist_ok=True)
        f = open(os.path.join(CONFIG_DIR, "app.lock"), "a+")
    except OSError:
        _LOCK = object()  # cannot create the lock file: just run
        return _LOCK
    try:
        if IS_WIN:
            import msvcrt
            f.seek(0)
            msvcrt.locking(f.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError as e:
        if getattr(e, "errno", None) in (errno.EACCES, errno.EAGAIN, errno.EDEADLK):
            f.close()
            return None
    except Exception:
        pass
    _LOCK = f  # keep open: the lock is released when the process exits
    return _LOCK


# ------------------------------------------------------- dark / light theme
DARK = dict(
    bg="#12141a", card="#1b1e27", field="#242836", border="#2f3446",
    text="#eef0f6", muted="#8a90a3", accent="#6c8cff",
    green="#2fbf71", green_h="#3fd281", red="#ef5b5b", red_h="#ff7272",
    amber="#f2b84b", warn_bg="#3a2f14", tile="#e9ecf5",
)
LIGHT = dict(
    bg="#f2f3f8", card="#ffffff", field="#eceef6", border="#d3d8e6",
    text="#1b1e2b", muted="#656b80", accent="#4f6ef0",
    green="#1fa35c", green_h="#27b96b", red="#dc4444", red_h="#ec5a5a",
    amber="#8a5a00", warn_bg="#fff1cc", tile="#e4e7f2",
)
C = dict(DARK)  # active palette (filled in by App)
SCALE = 1.0     # screen scale (high-DPI), filled in by App


def px(n):
    return int(round(n * SCALE))


def _run(cmd, timeout=1.5):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def _luma(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def _win_dark():
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER,
                            r"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize") as k:
            return winreg.QueryValueEx(k, "AppsUseLightTheme")[0] == 0
    except Exception:
        return None


def _kde_dark():
    try:
        with open(os.path.expanduser("~/.config/kdeglobals"), encoding="utf-8", errors="ignore") as f:
            text = f.read()
    except OSError:
        return None
    m = re.search(r"\[Colors:Window\][^\[]*?BackgroundNormal=(\d+),(\d+),(\d+)", text, re.S)
    if m:
        return _luma(*map(int, m.groups())) < 128
    m = re.search(r"^ColorScheme=(.+)$", text, re.M)
    if m:
        return "dark" in m.group(1).lower()
    return None


def _gtk_ini_dark():
    for ver in ("gtk-4.0", "gtk-3.0"):
        try:
            with open(os.path.expanduser(f"~/.config/{ver}/settings.ini"), encoding="utf-8", errors="ignore") as f:
                text = f.read()
        except OSError:
            continue
        m = re.search(r"^gtk-application-prefer-dark-theme\s*=\s*(\w+)", text, re.M | re.I)
        if m:
            return m.group(1).lower() in ("1", "true")
        m = re.search(r"^gtk-theme-name\s*=\s*(.+)$", text, re.M | re.I)
        if m:
            return "dark" in m.group(1).lower()
    return None


def system_is_dark():
    """True if the system uses a dark theme (defaults to dark if unknown)."""
    if IS_WIN:
        r = _win_dark()
        return True if r is None else r
    if IS_MAC:
        return _run(["defaults", "read", "-g", "AppleInterfaceStyle"]).lower() == "dark"
    # 1) freedesktop portal: GNOME, KDE and most modern desktops
    out = _run(["gdbus", "call", "--session", "--dest", "org.freedesktop.portal.Desktop",
                "--object-path", "/org/freedesktop/portal/desktop",
                "--method", "org.freedesktop.portal.Settings.Read",
                "org.freedesktop.appearance", "color-scheme"])
    m = re.search(r"uint32 (\d)", out)
    if m and m.group(1) in ("1", "2"):
        return m.group(1) == "1"
    # 2) GNOME color-scheme
    out = _run(["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"])
    if "prefer-dark" in out:
        return True
    if "prefer-light" in out:
        return False
    # 3) KDE, 4) GTK settings file
    for fn in (_kde_dark, _gtk_ini_dark):
        r = fn()
        if r is not None:
            return r
    # 5) GTK theme name / GTK_THEME variable
    out = _run(["gsettings", "get", "org.gnome.desktop.interface", "gtk-theme"])
    if out:
        return "dark" in out.lower()
    env = os.environ.get("GTK_THEME", "")
    if env:
        return "dark" in env.lower()
    return True


# ---------------------------------------------------------- click backends
def is_wayland():
    t = os.environ.get("XDG_SESSION_TYPE", "").lower()
    if t:
        return t == "wayland"
    return bool(os.environ.get("WAYLAND_DISPLAY"))


def uinput_problem():
    """None if uinput is usable, otherwise a short reason."""
    if not os.path.exists("/dev/uinput"):
        return "/dev/uinput is missing (run: sudo modprobe uinput)"
    if not os.access("/dev/uinput", os.W_OK):
        return "no permission for /dev/uinput (log out and back in once, or run install.sh again)"
    return None


class BaseBackend:
    name = "base"

    def at_corner(self):
        """True when the mouse is in the top-left screen corner (safety stop)."""
        return False

    def close(self):
        pass


# Linux uinput constants (stable kernel ABI; same on x86 and ARM)
UI_DEV_CREATE = 0x5501
UI_DEV_DESTROY = 0x5502
UI_DEV_SETUP = 0x405C5503     # _IOW('U', 3, struct uinput_setup[92 bytes])
UI_SET_EVBIT = 0x40045564
UI_SET_KEYBIT = 0x40045565
UI_SET_RELBIT = 0x40045566
EV_SYN, EV_KEY, EV_REL = 0, 1, 2
BTN_LEFT, BTN_RIGHT, BTN_MIDDLE = 0x110, 0x111, 0x112
REL_X, REL_Y = 0, 1


class UInputBackend(BaseBackend):
    """Pure-Python uinput: a virtual mouse made through /dev/uinput. No extra packages.

    One click = one os.write() of four input events (press, sync, release, sync).
    """
    name = "uinput"
    CODES = {1: BTN_LEFT, 2: BTN_MIDDLE, 3: BTN_RIGHT}

    @staticmethod
    def available():
        return not IS_WIN and not IS_MAC and uinput_problem() is None

    def __init__(self):
        import fcntl
        import struct
        self._fcntl = fcntl
        self.fd = os.open("/dev/uinput", os.O_WRONLY)
        try:
            ioctl = fcntl.ioctl
            for ev in (EV_SYN, EV_KEY, EV_REL):
                ioctl(self.fd, UI_SET_EVBIT, ev)
            for code in (BTN_LEFT, BTN_RIGHT, BTN_MIDDLE):
                ioctl(self.fd, UI_SET_KEYBIT, code)
            # REL_X/REL_Y make the compositor treat this as a real pointer device
            for code in (REL_X, REL_Y):
                ioctl(self.fd, UI_SET_RELBIT, code)
            # struct uinput_setup { u16 bustype, vendor, product, version; char name[80]; u32 ff_effects_max; }
            ioctl(self.fd, UI_DEV_SETUP, struct.pack("HHHH80sI", 0x03, 0x1234, 0x5678, 1, b"fast-autoclicker", 0))
            ioctl(self.fd, UI_DEV_CREATE)
        except BaseException:
            os.close(self.fd)
            self.fd = None
            raise

        def ev(t, c, v):
            return struct.pack("llHHi", 0, 0, t, c, v)  # struct input_event (time is filled in by the kernel)
        self._packets = {
            b: ev(EV_KEY, code, 1) + ev(EV_SYN, 0, 0) + ev(EV_KEY, code, 0) + ev(EV_SYN, 0, 0)
            for b, code in self.CODES.items()}
        time.sleep(0.3)  # let the compositor register the new device

    def click(self, button):
        data = self._packets[button]
        if os.write(self.fd, data) != len(data):
            raise OSError("short write to /dev/uinput")

    def close(self):
        if self.fd is None:
            return
        fd, self.fd = self.fd, None
        try:
            self._fcntl.ioctl(fd, UI_DEV_DESTROY)
        finally:
            os.close(fd)


class XTestBackend(BaseBackend):
    name = "xtest"

    @staticmethod
    def available():
        if IS_WIN or IS_MAC or is_wayland() or not os.environ.get("DISPLAY"):
            return False
        return bool(ctypes.util.find_library("X11") and ctypes.util.find_library("Xtst"))

    def __init__(self):
        self.x11 = ctypes.CDLL(ctypes.util.find_library("X11"))
        self.xtst = ctypes.CDLL(ctypes.util.find_library("Xtst"))
        self.x11.XOpenDisplay.restype = ctypes.c_void_p
        self.x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.x11.XFlush.argtypes = [ctypes.c_void_p]
        self.x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xtst.XTestFakeButtonEvent.argtypes = [
            ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.dpy = self.x11.XOpenDisplay(None)
        if not self.dpy:
            raise RuntimeError("Cannot open X display")

    def click(self, button):
        self.xtst.XTestFakeButtonEvent(self.dpy, button, 1, 0)
        self.xtst.XTestFakeButtonEvent(self.dpy, button, 0, 0)
        self.x11.XFlush(self.dpy)

    def close(self):
        self.x11.XCloseDisplay(self.dpy)


class SubprocessBackend(BaseBackend):
    name = "slow mode"
    YCODES = {1: "0xC0", 3: "0xC1", 2: "0xC2"}

    @staticmethod
    def pick_tool():
        if IS_WIN or IS_MAC:
            return None
        # xdotool does not work on native Wayland, so only ydotool is allowed there
        order = ["ydotool"] if is_wayland() else ["xdotool", "ydotool"]
        return next((t for t in order if shutil.which(t)), None)

    @staticmethod
    def available():
        return SubprocessBackend.pick_tool() is not None

    def __init__(self):
        self.tool = self.pick_tool()
        if not self.tool:
            raise RuntimeError("no xdotool/ydotool found")

    def click(self, button):
        if self.tool == "xdotool":
            cmd = ["xdotool", "click", str(button)]
        else:
            cmd = ["ydotool", "click", self.YCODES[button]]
        subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=True)


# --- Windows: SendInput (structures are plain ctypes, so they can be tested anywhere)
class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_int32), ("y", ctypes.c_int32)]


class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_int32), ("dy", ctypes.c_int32), ("mouseData", ctypes.c_uint32),
                ("dwFlags", ctypes.c_uint32), ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", ctypes.c_uint16), ("wScan", ctypes.c_uint16), ("dwFlags", ctypes.c_uint32),
                ("time", ctypes.c_uint32), ("dwExtraInfo", ctypes.c_size_t)]


class HARDWAREINPUT(ctypes.Structure):
    _fields_ = [("uMsg", ctypes.c_uint32), ("wParamL", ctypes.c_uint16), ("wParamH", ctypes.c_uint16)]


class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]


class INPUT(ctypes.Structure):
    _fields_ = [("type", ctypes.c_uint32), ("u", _INPUTUNION)]


class MSG(ctypes.Structure):
    _fields_ = [("hwnd", ctypes.c_void_p), ("message", ctypes.c_uint32), ("wParam", ctypes.c_size_t),
                ("lParam", ctypes.c_ssize_t), ("time", ctypes.c_uint32), ("pt", POINT)]


class WindowsBackend(BaseBackend):
    name = "windows"
    DOWN = {1: 0x0002, 2: 0x0020, 3: 0x0008}  # LEFT/MIDDLE/RIGHT DOWN
    UP = {1: 0x0004, 2: 0x0040, 3: 0x0010}    # LEFT/MIDDLE/RIGHT UP

    @staticmethod
    def available():
        return IS_WIN

    def __init__(self, user32=None, winmm=None):
        self._winmm = None
        if user32 is None:
            user32 = ctypes.WinDLL("user32", use_last_error=True)
            user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]
            user32.SendInput.restype = ctypes.c_uint
            user32.GetCursorPos.argtypes = [ctypes.POINTER(POINT)]
            user32.GetCursorPos.restype = ctypes.c_int
            try:
                winmm = ctypes.WinDLL("winmm")
            except OSError:
                winmm = None
        self.u = user32
        if winmm is not None:
            try:
                winmm.timeBeginPeriod(1)  # 1 ms timer resolution instead of ~15 ms
                self._winmm = winmm
            except Exception:
                pass
        self.size = ctypes.sizeof(INPUT)
        self.arrays = {}
        for b in (1, 2, 3):
            arr = (INPUT * 2)()
            for i, flag in enumerate((self.DOWN[b], self.UP[b])):
                arr[i].type = 0  # INPUT_MOUSE
                arr[i].u.mi.dwFlags = flag
            self.arrays[b] = arr

    def click(self, button):
        if self.u.SendInput(2, self.arrays[button], self.size) != 2:
            code = getattr(ctypes, "get_last_error", lambda: 0)()
            raise OSError("Windows blocked the click (code %s). If the target program runs as "
                          "administrator, start %s as administrator too." % (code, APP_NAME))

    def at_corner(self):
        pt = POINT()
        try:
            if self.u.GetCursorPos(ctypes.byref(pt)):
                return pt.x <= 1 and pt.y <= 1
        except Exception:
            pass
        return False

    def close(self):
        if self._winmm is not None:
            try:
                self._winmm.timeEndPeriod(1)
            except Exception:
                pass
            self._winmm = None


def win_hotkey_loop(on_press, on_fail, user32=None):
    """Global F6 hotkey for Windows (RegisterHotKey, no extra packages). Runs in its own thread."""
    try:
        u = user32 or ctypes.WinDLL("user32", use_last_error=True)
        if user32 is None:
            u.RegisterHotKey.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_uint, ctypes.c_uint]
            u.GetMessageW.argtypes = [ctypes.POINTER(MSG), ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
        if not u.RegisterHotKey(None, 1, 0x4000, 0x75):  # MOD_NOREPEAT, VK_F6
            on_fail()
            return
        msg = MSG()
        while u.GetMessageW(ctypes.byref(msg), None, 0, 0) > 0:
            if msg.message == 0x0312:  # WM_HOTKEY
                on_press()
    except Exception:
        on_fail()


# --- macOS: Quartz CGEvent through ctypes (no extra packages)
class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_MAC_LIBS = None


def _mac_libs():
    global _MAC_LIBS
    if _MAC_LIBS is None:
        def load(name):
            return ctypes.CDLL(ctypes.util.find_library(name)
                               or "/System/Library/Frameworks/%s.framework/%s" % (name, name))
        cg, cf, ax = load("CoreGraphics"), load("CoreFoundation"), load("ApplicationServices")
        cg.CGEventCreate.restype = ctypes.c_void_p
        cg.CGEventCreate.argtypes = [ctypes.c_void_p]
        cg.CGEventGetLocation.restype = CGPoint
        cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
        cg.CGEventCreateMouseEvent.restype = ctypes.c_void_p
        cg.CGEventCreateMouseEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
        cg.CGEventPost.restype = None
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CGEventSetIntegerValueField.restype = None
        cg.CGEventSetIntegerValueField.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_int64]
        cf.CFRelease.restype = None
        cf.CFRelease.argtypes = [ctypes.c_void_p]
        ax.AXIsProcessTrusted.restype = ctypes.c_bool
        ax.AXIsProcessTrusted.argtypes = []
        _MAC_LIBS = types.SimpleNamespace(cg=cg, cf=cf, ax=ax)
    return _MAC_LIBS


def open_mac_privacy():
    try:
        subprocess.Popen(["open", "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"])
    except Exception:
        pass


class MacBackend(BaseBackend):
    name = "macos"
    DOWN = {1: 1, 3: 3, 2: 25}  # left / right / other mouse down
    UP = {1: 2, 3: 4, 2: 26}    # left / right / other mouse up
    BTN = {1: 0, 3: 1, 2: 2}    # kCGMouseButtonLeft / Right / Center

    @staticmethod
    def available():
        return IS_MAC

    @staticmethod
    def trusted(libs=None):
        """True if macOS lets this program post clicks (Accessibility permission)."""
        try:
            return bool((libs or _mac_libs()).ax.AXIsProcessTrusted())
        except Exception:
            return True  # cannot tell: do not block

    def __init__(self, libs=None):
        self.l = libs or _mac_libs()

    def _pos(self):
        ev = self.l.cg.CGEventCreate(None)
        pos = self.l.cg.CGEventGetLocation(ev)
        self.l.cf.CFRelease(ev)
        return pos

    def click(self, button):
        cg, cf = self.l.cg, self.l.cf
        pos = self._pos()
        for etype in (self.DOWN[button], self.UP[button]):
            ev = cg.CGEventCreateMouseEvent(None, etype, pos, self.BTN[button])
            if not ev:
                raise RuntimeError("macOS refused to create a click event")
            cg.CGEventSetIntegerValueField(ev, 1, 1)  # click state 1: every click is a single click
            cg.CGEventPost(0, ev)                     # kCGHIDEventTap
            cf.CFRelease(ev)

    def at_corner(self):
        try:
            pos = self._pos()
            return pos.x <= 1 and pos.y <= 1
        except Exception:
            return False


def candidate_backends():
    if IS_WIN:
        return [WindowsBackend]
    if IS_MAC:
        return [MacBackend]
    return [UInputBackend, XTestBackend, SubprocessBackend]


def make_backend():
    """Return (fastest working backend instance, None) or (None, error text)."""
    errors = []
    for cls in candidate_backends():
        if not cls.available():
            continue
        try:
            return cls(), None
        except Exception as ex:
            errors.append(f"{cls.name}: {ex}")
    if not errors and not IS_WIN and not IS_MAC:
        errors.append(uinput_problem() or "no click method available")
    return None, "; ".join(errors) or "no click method available"


def detect_backend_name():
    for cls in candidate_backends():
        if cls.available():
            return cls.name
    return None


def preflight():
    """A message if clicking cannot work right now (e.g. missing macOS permission), else None."""
    if IS_MAC and not MacBackend.trusted():
        return ("macOS needs your permission to click. In System Settings > Privacy & Security > "
                "Accessibility, turn on %s (or Python), then press Start again." % APP_NAME)
    return None


def run_check():
    _p(f"{APP_NAME} diagnostics")
    _p(f"  system    : {sys.platform}, python {sys.version.split()[0]}, tk {tk.TkVersion}")
    if not IS_WIN and not IS_MAC:
        _p(f"  session   : {'wayland' if is_wayland() else 'x11 / other'}")
    for cls in candidate_backends():
        _p(f"  {cls.name:<9} : {'available' if cls.available() else 'not available'}")
    if not IS_WIN and not IS_MAC:
        _p(f"  uinput    : {uinput_problem() or 'ok'}")
    active = detect_backend_name()
    _p(f"  using     : {active or 'nothing (no click method found)'}")
    pre = preflight()
    if pre:
        _p(f"  WARNING   : {pre}")
    _p(f"  settings  : {CONFIG_FILE}")
    _p(f"  error log : {LOG_FILE}")
    return 0 if active else 1


# ----------------------------------------------------------- custom widgets
def round_rect(cv, x1, y1, x2, y2, r, **kw):
    pts = [x1 + r, y1, x2 - r, y1, x2, y1, x2, y1 + r, x2, y2 - r, x2, y2,
           x2 - r, y2, x1 + r, y2, x1, y2, x1, y2 - r, x1, y1 + r, x1, y1]
    return cv.create_polygon(pts, smooth=True, **kw)


class RoundButton(tk.Canvas):
    """A big rounded button drawn on a canvas."""

    def __init__(self, parent, text, command, color, hover, font, width=340, height=52, radius=16):
        width, height, radius = px(width), px(height), px(radius)
        super().__init__(parent, width=width, height=height, bg=C["bg"],
                         highlightthickness=0, bd=0, cursor="hand2")
        self.w, self.h = width, height
        self.command = command
        self.color, self.hover = color, hover
        self.shape = round_rect(self, 1, 1, width - 1, height - 1, radius, fill=color, outline=color)
        self.label = self.create_text(width // 2, height // 2, text=text, fill="#ffffff", font=font)
        self.bind("<Enter>", lambda e: self._paint(self.hover))
        self.bind("<Leave>", lambda e: self._paint(self.color))
        self.bind("<ButtonRelease-1>", self._released)

    def _released(self, e):
        if 0 <= e.x <= self.w and 0 <= e.y <= self.h:
            self.command()

    def _paint(self, color):
        self.itemconfigure(self.shape, fill=color, outline=color)

    def restyle(self, text, color, hover):
        self.color, self.hover = color, hover
        self.itemconfigure(self.label, text=text)
        self._paint(color)


class Stepper(tk.Frame):
    """Number field with - / + buttons (hold to repeat, mouse wheel works)."""

    def __init__(self, parent, var, lo, hi, step, font, width=9):
        super().__init__(parent, bg=C["field"], highlightthickness=1,
                         highlightbackground=C["border"], highlightcolor=C["accent"])
        self.var, self.lo, self.hi, self.step = var, lo, hi, step
        self._job = None
        minus = self._make_btn("-", -1, font)
        plus = self._make_btn("+", 1, font)
        self.entry = tk.Entry(
            self, textvariable=var, width=width, justify="center", relief="flat", bd=0,
            bg=C["field"], fg=C["text"], insertbackground=C["text"], highlightthickness=0,
            font=font, validate="key",
            validatecommand=(self.register(lambda s: s == "" or (s.isdigit() and len(s) <= 9)), "%P"))
        minus.pack(side="left")
        plus.pack(side="right")
        self.entry.pack(side="left", fill="x", expand=True, ipady=5)
        self.entry.bind("<Button-4>", lambda e: self.bump(1))
        self.entry.bind("<Button-5>", lambda e: self.bump(-1))
        self.entry.bind("<MouseWheel>", lambda e: self.bump(1 if e.delta > 0 else -1))
        self.entry.bind("<FocusOut>", lambda e: self.bump(0))  # clamp typed value

    def _make_btn(self, text, sign, font):
        lb = tk.Label(self, text=text, width=3, bg=C["field"], fg=C["muted"], font=font, cursor="hand2")
        lb.bind("<Enter>", lambda e: lb.config(fg=C["text"]))
        lb.bind("<Leave>", lambda e: lb.config(fg=C["muted"]))
        lb.bind("<ButtonPress-1>", lambda e: self._start(sign))
        lb.bind("<ButtonRelease-1>", lambda e: self._stop())
        return lb

    def _start(self, sign):
        self.bump(sign)
        self._job = self.after(400, lambda: self._repeat(sign))

    def _repeat(self, sign):
        self.bump(sign)
        self._job = self.after(60, lambda: self._repeat(sign))

    def _stop(self):
        if self._job:
            self.after_cancel(self._job)
            self._job = None

    def bump(self, sign):
        try:
            v = int(self.var.get() or 0)
        except ValueError:
            v = 0
        self.var.set(str(max(self.lo, min(self.hi, v + sign * self.step))))


class Segmented(tk.Frame):
    """Pill-style choice (Left / Middle / Right)."""

    def __init__(self, parent, var, options, font):
        super().__init__(parent, bg=C["field"], highlightthickness=1, highlightbackground=C["border"])
        self.var = var
        self.labels = {}
        for opt in options:
            lb = tk.Label(self, text=opt, font=font, padx=11, pady=5, cursor="hand2")
            lb.pack(side="left")
            lb.bind("<Button-1>", lambda e, o=opt: var.set(o))
            self.labels[opt] = lb
        var.trace_add("write", lambda *a: self.refresh())
        self.refresh()

    def refresh(self):
        for opt, lb in self.labels.items():
            if opt == self.var.get():
                lb.config(bg=C["accent"], fg="#ffffff")
            else:
                lb.config(bg=C["field"], fg=C["muted"])


# --------------------------------------------------------------------- app
class App:
    def __init__(self, root):
        global SCALE
        self.root = root
        self.stop_event = threading.Event()
        self.thread = None
        self.q = queue.Queue()  # the click thread never touches Tk: it only posts here
        self._last_toggle = 0.0
        self._save_job = None
        self._warned = False
        self._closing = False
        self.backend_name = detect_backend_name()

        try:
            SCALE = max(1.0, min(3.0, root.winfo_fpixels("1i") / 96.0))
        except Exception:
            SCALE = 1.0
        self.dark = system_is_dark()
        C.clear()
        C.update(DARK if self.dark else LIGHT)

        base = tkfont.nametofont("TkDefaultFont").actual("family")
        self.f_title = tkfont.Font(family=base, size=16, weight="bold")
        self.f_body = tkfont.Font(family=base, size=10)
        self.f_hint = tkfont.Font(family=base, size=9)
        self.f_hint_b = tkfont.Font(family=base, size=9, weight="bold")
        self.f_big = tkfont.Font(family=base, size=28, weight="bold")
        self.f_rate = tkfont.Font(family=base, size=15, weight="bold")
        self.f_btn = tkfont.Font(family=base, size=13, weight="bold")

        s = load_settings()
        self.v_interval = tk.StringVar(value=str(s["interval"]))
        self.v_button = tk.StringVar(value=s["button"])
        self.v_count = tk.StringVar(value=str(s["count"]))
        self.v_delay = tk.StringVar(value=str(s["delay"]))

        root.title(APP_NAME)
        root.configure(bg=C["bg"])
        root.resizable(False, False)
        try:
            root.report_callback_exception = self.on_tk_error
        except Exception:
            pass
        self.build()

        for v in (self.v_interval, self.v_button, self.v_count, self.v_delay):
            v.trace_add("write", self.on_change)
        root.protocol("WM_DELETE_WINDOW", self.on_close)
        root.bind("<F6>", lambda e: self.toggle())
        self.start_global_hotkey()
        self.update_warning()
        root.after(40, self.poll)

    # ---- layout
    def build(self):
        pad = tk.Frame(self.root, bg=C["bg"])
        pad.pack(padx=22, pady=20)

        # header: logo tile, title, backend badge
        head = tk.Frame(pad, bg=C["bg"])
        head.pack(fill="x")
        t = px(48)
        tile = tk.Canvas(head, width=t, height=t, bg=C["bg"], highlightthickness=0)
        round_rect(tile, 1, 1, t - 1, t - 1, px(14), fill=C["tile"], outline=C["tile"])
        self.logo = None
        try:
            img = tk.PhotoImage(file=os.path.join(HERE, "icon.png"))
            f = max(1, img.width() // px(36))
            self.logo = img.subsample(f, f)
            tile.create_image(t // 2, t // 2, image=self.logo)
        except Exception:
            pass
        tile.pack(side="left")
        titles = tk.Frame(head, bg=C["bg"])
        titles.pack(side="left", padx=12)
        tk.Label(titles, text=APP_NAME, font=self.f_title, bg=C["bg"], fg=C["text"]).pack(anchor="w")
        tk.Label(titles, text="Fast auto clicker", font=self.f_hint, bg=C["bg"], fg=C["muted"]).pack(anchor="w")
        if self.backend_name is None:
            badge, bcolor = "no backend", C["red"]
        elif self.backend_name == "slow mode":
            badge, bcolor = "slow mode", C["amber"]
        else:
            badge, bcolor = self.backend_name, C["green"]
        tk.Label(head, text=badge, font=self.f_hint_b, bg=C["field"], fg=bcolor,
                 padx=10, pady=3).pack(side="right")

        # settings card
        card = tk.Frame(pad, bg=C["card"], highlightthickness=1, highlightbackground=C["border"])
        card.pack(fill="x", pady=(18, 12))
        inner = tk.Frame(card, bg=C["card"])
        inner.pack(fill="x", padx=16, pady=10)
        inner.columnconfigure(0, weight=1)

        self.row(inner, 0, "Interval", "milliseconds",
                 Stepper(inner, self.v_interval, 0, 60000, 1, self.f_body))

        # warning for 0-1 ms (shown only when needed)
        self.warn = tk.Frame(inner, bg=C["warn_bg"])
        tk.Label(self.warn, font=self.f_hint, bg=C["warn_bg"], fg=C["amber"], justify="left",
                 anchor="w", wraplength=px(230),
                 text="Warning: 0-1 ms can freeze or crash browsers and games. 50 ms or more is safer."
                 ).pack(side="left", padx=(10, 8), pady=8)
        fix = tk.Label(self.warn, text="Use 50", font=self.f_hint_b, bg=C["amber"], fg=C["warn_bg"],
                       padx=8, pady=3, cursor="hand2")
        fix.pack(side="right", padx=(0, 10))
        fix.bind("<Button-1>", lambda e: self.v_interval.set("50"))
        self.warn.grid(row=1, column=0, columnspan=2, sticky="ew", pady=(0, 6))

        self.row(inner, 2, "Mouse button", "which button to click",
                 Segmented(inner, self.v_button, list(BUTTONS), self.f_body))
        self.row(inner, 3, "Click limit", "0 = endless",
                 Stepper(inner, self.v_count, 0, 100000000, 10, self.f_body))
        self.row(inner, 4, "Start delay", "seconds",
                 Stepper(inner, self.v_delay, 0, 60, 1, self.f_body))

        # live stats card
        stats = tk.Frame(pad, bg=C["card"], highlightthickness=1, highlightbackground=C["border"])
        stats.pack(fill="x", pady=(0, 12))
        si = tk.Frame(stats, bg=C["card"])
        si.pack(fill="x", padx=16, pady=10)
        left = tk.Frame(si, bg=C["card"])
        left.pack(side="left")
        self.lbl_count = tk.Label(left, text="0", font=self.f_big, bg=C["card"], fg=C["text"])
        self.lbl_count.pack(anchor="w")
        tk.Label(left, text="clicks", font=self.f_hint, bg=C["card"], fg=C["muted"]).pack(anchor="w")
        right = tk.Frame(si, bg=C["card"])
        right.pack(side="right")
        self.lbl_rate = tk.Label(right, text="0 /s", font=self.f_rate, bg=C["card"], fg=C["accent"])
        self.lbl_rate.pack(anchor="e")
        tk.Label(right, text="speed", font=self.f_hint, bg=C["card"], fg=C["muted"]).pack(anchor="e")

        # start / stop
        self.btn = RoundButton(pad, "Start  (F6)", self.toggle, C["green"], C["green_h"], self.f_btn)
        self.btn.pack()

        self.status = tk.StringVar()
        self.lbl_status = tk.Label(pad, textvariable=self.status, font=self.f_hint, bg=C["bg"],
                                   fg=C["muted"], wraplength=px(340), justify="left")
        self.lbl_status.pack(anchor="w", pady=(12, 0))

        text, kind = self.initial_status()
        self.set_status(text, kind)
        if self.backend_name is None:
            self.btn.restyle("Unavailable", C["border"], C["border"])

    def initial_status(self):
        pre = preflight()
        if pre:
            return pre, "warn"
        if IS_WIN or IS_MAC:
            if IS_MAC:
                return "Ready. Move the mouse to the top-left corner of the screen to stop clicking.", "info"
            return "Ready. Press Start, then move the mouse to your target.", "info"
        reason = uinput_problem()
        if self.backend_name is None:
            return f"No click method found: {reason}. Run install.sh again.", "err"
        if self.backend_name == "slow mode":
            return f"Slow mode (much slower). uinput is not usable: {reason}.", "warn"
        if self.backend_name == "xtest":
            return f"Using X11 mode. For Wayland support, fix uinput: {reason}.", "warn"
        return "Ready. Press Start, then move the mouse to your target.", "info"

    def row(self, parent, r, title, hint, widget):
        lab = tk.Frame(parent, bg=C["card"])
        lab.grid(row=r, column=0, sticky="w", pady=7)
        tk.Label(lab, text=title, font=self.f_body, bg=C["card"], fg=C["text"]).pack(anchor="w")
        tk.Label(lab, text=hint, font=self.f_hint, bg=C["card"], fg=C["muted"]).pack(anchor="w")
        widget.grid(row=r, column=1, sticky="e", pady=7)

    # ---- settings
    def read_settings(self):
        def num(var, lo, hi, default):
            try:
                n = int(var.get())
            except (ValueError, tk.TclError):
                n = default
            return max(lo, min(hi, n))
        button = self.v_button.get()
        return {
            "interval": num(self.v_interval, 0, 60000, DEFAULTS["interval"]),
            "button": button if button in BUTTONS else "Left",
            "count": num(self.v_count, 0, 100000000, DEFAULTS["count"]),
            "delay": num(self.v_delay, 0, 60, DEFAULTS["delay"]),
        }

    def save(self):
        self._save_job = None
        save_settings(self.read_settings())

    def on_change(self, *args):
        self.update_warning()
        if self._save_job:
            self.root.after_cancel(self._save_job)
        self._save_job = self.root.after(500, self.save)

    def update_warning(self):
        if self.read_settings()["interval"] <= 1:
            self.warn.grid()
        else:
            self.warn.grid_remove()

    def on_close(self):
        self._closing = True
        try:
            self.save()
        finally:
            self.stop_event.set()
            t = self.thread
            if t and t.is_alive():
                t.join(1.5)  # let the click thread close its device cleanly
            self.root.destroy()

    def on_tk_error(self, exc, val, tb):
        log_error("".join(traceback.format_exception(exc, val, tb)))
        try:
            self.set_status(f"Internal error (saved to {LOG_FILE})", "err")
        except Exception:
            pass

    # ---- thread-safe UI queue: the click thread only calls ui(), never Tk directly
    def ui(self, fn, *args):
        self.q.put((fn, args))

    def poll(self):
        if self._closing:
            return
        self.root.after(40, self.poll)
        self.drain()

    def drain(self):
        while True:
            try:
                fn, args = self.q.get_nowait()
            except queue.Empty:
                return
            try:
                fn(*args)
            except Exception:
                log_error(traceback.format_exc())

    # ---- status helpers
    def set_status(self, text, kind="info"):
        color = {"info": C["muted"], "ok": C["green"], "warn": C["amber"], "err": C["red"]}[kind]
        self.status.set(text)
        self.lbl_status.config(fg=color)

    def set_stats(self, done, rate):
        self.lbl_count.config(text=f"{done:,}")
        self.lbl_rate.config(text=f"{rate:,.0f} /s")

    def set_running(self, running):
        if running:
            self.btn.restyle("Stop  (F6)", C["red"], C["red_h"])
        else:
            self.btn.restyle("Start  (F6)", C["green"], C["green_h"])

    # ---- global hotkey
    def start_global_hotkey(self):
        if IS_WIN:
            threading.Thread(
                target=win_hotkey_loop, daemon=True,
                args=(lambda: self.ui(self.toggle),
                      lambda: self.ui(self.set_status,
                                      "Global F6 is unavailable (used by another program). "
                                      "F6 still works inside this window.", "warn"))).start()
            return
        if IS_MAC:
            return  # a global key listener can crash Tk on macOS; use the window F6 + corner stop
        # Linux: works on X11 if pynput is installed; on Wayland F6 only works with this window focused
        try:
            from pynput import keyboard
            listener = keyboard.GlobalHotKeys({"<f6>": lambda: self.ui(self.toggle)})
            listener.daemon = True
            listener.start()
        except Exception:
            pass

    # ---- start / stop
    def toggle(self):
        if self.backend_name is None:
            return
        # F6 can arrive twice (window binding + global hotkey): count it once
        now = time.monotonic()
        if now - self._last_toggle < 0.4:
            return
        self._last_toggle = now
        if self.thread and self.thread.is_alive():
            self.stop_event.set()
            return

        pre = preflight()
        if pre:
            self.set_status(pre, "err")
            if IS_MAC:
                open_mac_privacy()
            return

        cfg = self.read_settings()
        self.save()
        if cfg["interval"] <= 1 and not self._warned:
            go = messagebox.askyesno(
                "Very fast clicking",
                "An interval of 0-1 ms sends thousands of clicks per second.\n"
                "Browsers, games and some apps can freeze or crash.\n\n"
                "50 ms or higher is much safer.\n\nStart anyway?",
                icon="warning", parent=self.root)
            if not go:
                return
            self._warned = True

        self.stop_event.clear()
        self.thread = threading.Thread(target=self.run, args=(cfg,), daemon=True)
        self.thread.start()
        self.set_running(True)

    def run(self, cfg):
        """Runs in a worker thread. Never touches Tk: results go through self.ui()."""
        backend = None
        done = 0
        error = None
        reason = None
        perf = time.perf_counter
        start = perf()
        try:
            interval = cfg["interval"] / 1000.0
            total = cfg["count"]
            delay = cfg["delay"]
            button = BUTTONS[cfg["button"]]

            backend, err = make_backend()
            if backend is None:
                raise RuntimeError(f"Could not start clicking: {err}")

            for s in range(delay, 0, -1):
                if self.stop_event.is_set():
                    break
                self.ui(self.set_status, f"Starting in {s}... move the mouse to the target.", "warn")
                for _ in range(10):
                    if self.stop_event.is_set():
                        break
                    time.sleep(0.1)

            click = backend.click
            corner = backend.at_corner
            check_corner = type(backend).at_corner is not BaseBackend.at_corner
            stopped = self.stop_event.is_set
            start = perf()
            last_ui = last_fs = next_t = start
            if not stopped():
                self.ui(self.set_status, "Clicking...", "ok")

            while not stopped() and (total == 0 or done < total):
                click(button)
                done += 1

                if interval > 0:
                    next_t += interval
                    wait = next_t - perf()
                    if wait > 0.002:
                        time.sleep(wait - 0.001)
                    while perf() < next_t:  # precise finish for small gaps
                        pass
                    if wait < -0.1:  # fell far behind, don't try to catch up
                        next_t = perf()
                else:
                    time.sleep(0)  # let the GUI thread breathe at maximum speed

                now = perf()
                if check_corner and now - last_fs >= 0.1:
                    last_fs = now
                    if corner():
                        reason = "mouse moved to the top-left corner"
                        break
                if now - last_ui >= 0.25:
                    last_ui = now
                    self.ui(self.set_stats, done, done / max(now - start, 1e-9))
        except Exception as ex:
            error = f"{type(ex).__name__}: {ex}"
            log_error(traceback.format_exc())
        finally:
            try:
                if backend is not None:
                    backend.close()
            except Exception:
                pass
            elapsed = max(perf() - start, 1e-9)
            self.ui(self.set_stats, done, done / elapsed)
            if error:
                self.ui(self.set_status, error, "err")
            elif reason:
                self.ui(self.set_status, f"Stopped after {done:,} clicks ({reason}).", "info")
            else:
                self.ui(self.set_status, f"Stopped after {done:,} clicks.", "info")
            self.ui(self.set_running, False)


def main():
    if "--check" in sys.argv[1:]:
        return run_check()
    if IS_WIN:
        try:  # own taskbar identity (so the taskbar shows our icon, not Python's)
            ctypes.windll.shell32.SetCurrentProcessExplicitAppUserModelID(APP_NAME + ".App")
        except Exception:
            pass
        try:  # crisp text on high-DPI screens
            ctypes.windll.shcore.SetProcessDpiAwareness(1)
        except Exception:
            pass
    lock = acquire_single_instance()
    try:
        root = tk.Tk(className=APP_NAME)
    except tk.TclError as ex:
        sys.stderr.write(f"{APP_NAME}: cannot open a window ({ex}). Is a desktop session running?\n")
        return 1
    if lock is None:
        root.withdraw()
        messagebox.showinfo(APP_NAME, f"{APP_NAME} is already running.")
        root.destroy()
        return 0
    try:
        icon = tk.PhotoImage(file=os.path.join(HERE, "icon.png"))
        root.iconphoto(True, icon)
    except Exception:
        pass
    try:
        App(root)
        root.mainloop()
    except Exception:
        log_error(traceback.format_exc())
        try:
            messagebox.showerror(APP_NAME, f"Something went wrong. Details were saved to:\n{LOG_FILE}")
        except Exception:
            pass
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
PYEOF
chmod +x "$INSTALL_DIR/$APP_ID.py"

# ------------------------------------------------------------------ 3. icon
if [ -f "$SCRIPT_DIR/cursor.png" ]; then
    cp "$SCRIPT_DIR/cursor.png" "$INSTALL_DIR/icon.png"
elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$REPO_RAW/cursor.png" -o "$INSTALL_DIR/icon.png" || warn "Could not get cursor.png (app will have no icon)."
else
    warn "cursor.png not found next to install.sh (app will have no icon)."
fi
[ -f "$INSTALL_DIR/icon.png" ] && cp "$INSTALL_DIR/icon.png" "$ICON_DIR/$APP_ID.png" || true

# ------------------------------------------------- 4. app-menu launcher entry
cat > "$DESKTOP_FILE" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_NAME
GenericName=Auto Clicker
Comment=Fast auto clicker for Wayland and X11
Exec="$PY" "$INSTALL_DIR/$APP_ID.py"
Icon=$INSTALL_DIR/icon.png
Terminal=false
Categories=Utility;
StartupWMClass=$APP_NAME
Keywords=autoclicker;clicker;mouse;
EOF
chmod +x "$DESKTOP_FILE"

command -v update-desktop-database >/dev/null && update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
command -v gtk-update-icon-cache >/dev/null && gtk-update-icon-cache -f -t "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
command -v kbuildsycoca6 >/dev/null && kbuildsycoca6 >/dev/null 2>&1 || true

# ------------------------------------------------------------ 5. self-check
say "Checking the installation"
"$PY" "$INSTALL_DIR/$APP_ID.py" --check || true

say "$APP_NAME installed! Find it in your app menu."
if [ -n "$NEED_RELOGIN" ]; then
    echo "    IMPORTANT: log out and back in once so the 'input' group takes effect."
    echo "    (Until then it may run in a slower fallback mode.)"
fi
