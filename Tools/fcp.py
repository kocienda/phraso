"""fcp: drive Final Cut Pro through System Events and screen capture, so a caption file
or template can be checked without a person clicking.

    python3 Tools/fcp.py import file.fcpxml [--library 1]   # into the Nth recent library (1 = first row)
    python3 Tools/fcp.py open                               # open the browser's first item in the timeline
    python3 Tools/fcp.py frames 00:00:01:00 00:00:03:00 ... --out /tmp/frames.png
                                                            # park the playhead at each timecode, crop the
                                                            # viewer, and tile the crops into one PNG
    python3 Tools/fcp.py check file.fcpxml 00:00:01:00 ... --out /tmp/frames.png   # all three
    python3 Tools/fcp.py shot /tmp/fcp.png                  # the whole Final Cut window
    python3 Tools/fcp.py windows                            # what Final Cut has open

Final Cut has no scripting interface, so this reads the Accessibility tree for dialogs
and menus, posts mouse clicks (build/click) where only a click will do, and reads the
result off the screen. The host app needs Accessibility and Screen Recording permission.
Geometry assumes the main window at its default layout (the browser top-left, the
viewer top-right, the timeline below); the crop is the viewer's image area.

Imports land in whichever library is the first row of Final Cut's "Open Library"
dialog, which is the most recently used one. Every import adds an event named after
the file's event, so test files should carry distinct names.
"""

import argparse
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CLICK = ROOT / "build" / "click"
PROC = 'tell application "System Events" to tell process "Final Cut Pro"'

# Points, in the main window's coordinate space, for the default layout at 2874x1672.
BROWSER_FIRST_ITEM = (273, 180)
TIMELINE_EMPTY = (1150, 1581)
# The viewer's image area in capture pixels (2x), for a 16:9 project at 50%.
VIEWER_CROP = dict(x=2765, y=741, w=2175, h=1215)


def osa(script: str, timeout: float = 60) -> str:
    r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
    if r.returncode != 0:
        raise RuntimeError(r.stderr.strip() or r.stdout.strip())
    return r.stdout.strip()


def ensure_click() -> Path:
    src = ROOT / "Tools" / "fcp" / "click.swift"
    if not CLICK.exists() or CLICK.stat().st_mtime < src.stat().st_mtime:
        CLICK.parent.mkdir(exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(CLICK), str(src)], check=True)
    return CLICK


def windows() -> list[tuple[str, str]]:
    out = osa(f'{PROC} to get {{name, subrole}} of every window')
    parts = [p.strip() for p in out.split(",")] if out else []
    n = len(parts) // 2
    return list(zip(parts[:n], parts[n:]))


def main_window() -> tuple[int, int, int, int, int]:
    """(window id, x, y, w, h) of the main window, via the window server."""
    out = subprocess.run([str(ROOT / "build" / "winid")], capture_output=True, text=True).stdout
    for line in out.splitlines():
        parts = line.split(" ")
        if "Final Cut Pro" in line and len(parts) >= 6:
            return int(parts[0]), int(float(parts[-4])), int(float(parts[-3])), int(float(parts[-2])), int(float(parts[-1]))
    raise RuntimeError(f"no Final Cut main window: {out}")


def ensure_winid() -> None:
    exe = ROOT / "build" / "winid"
    src = ROOT / "Tools" / "fcp" / "winid.swift"
    if not exe.exists() or exe.stat().st_mtime < src.stat().st_mtime:
        exe.parent.mkdir(exist_ok=True)
        subprocess.run(["swiftc", "-O", "-o", str(exe), str(src)], check=True)


def wait_for_window(name: str, seconds: float = 20) -> None:
    t0 = time.time()
    while time.time() - t0 < seconds:
        if any(w == name for w, _ in windows()):
            return
        time.sleep(0.5)
    raise RuntimeError(f"no window named {name!r} after {seconds}s; windows: {windows()}")


def wait_until_gone(name: str, seconds: float = 60) -> None:
    t0 = time.time()
    while time.time() - t0 < seconds:
        if not any(w == name for w, _ in windows()):
            return
        time.sleep(0.5)
    raise RuntimeError(f"window {name!r} still open after {seconds}s")


def click_at(point: tuple[int, int], double: bool = False) -> None:
    _, wx, wy, _, _ = main_window()
    args = [str(ensure_click())] + (["double"] if double else []) + [str(wx + point[0]), str(wy + point[1])]
    subprocess.run(args, check=True)


def click_menu(path: list[str]) -> None:
    osa('tell application "Final Cut Pro" to activate')
    time.sleep(0.4)
    ref = f'menu bar item "{path[0]}" of menu bar 1'
    for item in path[1:]:
        ref = f'menu item "{item}" of menu 1 of {ref}'
    osa(f"{PROC} to click {ref}")


def shot(out: Path) -> Path:
    wid, *_ = main_window()
    subprocess.run(["screencapture", "-x", "-o", "-l", str(wid), str(out)], check=True)
    return out


def do_import(file: Path, library_row: int = 1) -> None:
    subprocess.run(["open", "-a", "Final Cut Pro", str(file.resolve())], check=True)
    wait_for_window("Open Library")
    osa(f'''{PROC}
        tell window "Open Library"
            select row {library_row} of table 1 of scroll area 1
            delay 0.3
            click button "Choose"
        end tell
    end tell''')
    wait_until_gone("Open Library")
    time.sleep(5)  # the browser repopulates and selects the new event


def do_open() -> None:
    click_at(BROWSER_FIRST_ITEM)
    time.sleep(0.8)
    click_menu(["Clip", "Open Clip"])
    time.sleep(2.5)


def goto(timecode: str) -> None:
    digits = timecode.replace(":", "").replace(";", "")
    osa(f'''{PROC}
        keystroke "p" using control down
        delay 0.3
        keystroke "{digits}"
        key code 36
    end tell''')


def do_frames(timecodes: list[str], out: Path, crop: dict | None = None) -> Path:
    c = VIEWER_CROP if crop is None else crop
    osa('tell application "Final Cut Pro" to activate')
    time.sleep(0.6)
    click_at(TIMELINE_EMPTY)
    time.sleep(0.5)
    tmp = Path("/tmp") / "fcp-frames"
    tmp.mkdir(exist_ok=True)
    for i, tc in enumerate(timecodes, 1):
        goto(tc)
        time.sleep(1.5)
        shot(tmp / f"full{i}.png")
        subprocess.run(["sips", "-c", str(c["h"]), str(c["w"]), "--cropOffset", str(c["y"]), str(c["x"]),
                        str(tmp / f"full{i}.png"), "--out", str(tmp / f"crop{i}.png")], check=True, capture_output=True)
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", str(tmp / "crop%d.png"), "-filter_complex",
                    f"scale=1000:-1,tile=1x{len(timecodes)}", "-frames:v", "1", "-update", "1", str(out)], check=True)
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("windows")
    p = sub.add_parser("import"); p.add_argument("file"); p.add_argument("--library", type=int, default=1)
    sub.add_parser("open")
    p = sub.add_parser("frames"); p.add_argument("timecodes", nargs="+"); p.add_argument("--out", default="/tmp/frames.png")
    p = sub.add_parser("check"); p.add_argument("file"); p.add_argument("timecodes", nargs="+"); p.add_argument("--out", default="/tmp/frames.png"); p.add_argument("--library", type=int, default=1)
    p = sub.add_parser("shot"); p.add_argument("out")
    a = ap.parse_args()
    ensure_winid()

    if a.cmd == "windows":
        for name, sub_ in windows():
            print(f"{sub_:20} {name!r}")
    elif a.cmd == "import":
        do_import(Path(a.file), a.library); print("imported")
    elif a.cmd == "open":
        do_open(); print("opened")
    elif a.cmd == "frames":
        print(do_frames(a.timecodes, Path(a.out)))
    elif a.cmd == "check":
        do_import(Path(a.file), a.library)
        do_open()
        print(do_frames(a.timecodes, Path(a.out)))
    elif a.cmd == "shot":
        print(shot(Path(a.out)))


if __name__ == "__main__":
    try:
        main()
    except RuntimeError as e:
        sys.exit(f"fcp: {e}")
