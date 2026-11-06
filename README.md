# Sautoclicker

**A very fast, modern auto clicker for Linux. Works on both Wayland and X11.**

Many Linux auto clickers rely on `xdotool`, which only works on X11. Sautoclicker sends clicks through the kernel (`uinput`), so it works on Wayland and X11 and can do thousands of clicks per second.

- Works on **Wayland and X11**
- Modern look that follows your system **dark / light** theme
- Your settings (interval, button, click limit, start delay) are **saved automatically**
- Live click counter and speed
- Needs only Python and Tk, no extra Python packages

> Linux only for now. Windows and macOS are planned.

---

# 📥 Install Guide

## Fastest way (works on any Linux)

```sh
git clone https://github.com/observer24434/Sautoclicker.git
```

# Step 1

# `cd Sautoclicker`

# Step 2

# `sh install.sh`

# ✅ Done!

## Log out and back in once, then open **Sautoclicker** from your app menu.

# 🖱️ How to use

1. Open **Sautoclicker**.
2. Set the **interval** in milliseconds. The default is `50` ms.
3. Choose the **mouse button** (left, middle or right).
4. Set a **click limit** (`0` = endless) and a **start delay** in seconds. Your settings are saved automatically.
5. Press **Start** (or **F6**), then move the mouse to your target during the countdown.
6. Press **F6** again, or click **Stop**, to stop.

Clicks always happen at the current mouse pointer position.

**About 0 and 1 ms:** these are the fastest settings, but they can freeze or crash browsers and games. The app shows a warning and a **Use 50** button. Most websites and games cannot use more than 100 to 200 clicks per second anyway.

## Wayland notes

- The global **F6** hotkey only works on X11. On Wayland, F6 works while the Sautoclicker window is focused.
- On Wayland you can also stop by moving the mouse onto the **Stop** button, using a click limit, or binding a key in your desktop settings to `pkill -f sautoclicker.py`.

---

- The badge in the app should say **uinput**. If it says **slow mode** or **xtest**, the check tells you why (usually: log out and back in once).

# 🗑️ Uninstall

```sh
sh install.sh --uninstall          # if installed with install.sh

---

## Files in this repo

- `install.sh` - one-file installer (contains the whole app)
- `cursor.png` - the app icon

## License

MIT, see [LICENSE](LICENSE).
