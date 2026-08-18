"""PID -> window handle discovery and foreground focusing (Win32)."""

from __future__ import annotations

import time

import psutil
import win32con
import win32gui
import win32process


def process_name(pid: int) -> str | None:
    """Return the process name for ``pid`` or ``None`` if it does not exist."""
    try:
        return psutil.Process(pid).name()
    except (psutil.NoSuchProcess, psutil.AccessDenied):
        return None


def find_hwnds_for_pid(pid: int) -> list[tuple[int, str]]:
    """Return visible top-level (hwnd, title) pairs owned by ``pid``."""
    results: list[tuple[int, str]] = []

    def _enum(hwnd, _):
        if not win32gui.IsWindowVisible(hwnd):
            return
        _, wpid = win32process.GetWindowThreadProcessId(hwnd)
        if wpid != pid:
            return
        title = win32gui.GetWindowText(hwnd)
        if title:
            results.append((hwnd, title))

    win32gui.EnumWindows(_enum, None)
    return results


def find_pids_by_name(name_substr: str) -> list[tuple[int, str, str]]:
    """Return (pid, process_name, first_window_title) matching ``name_substr``."""
    name_substr = name_substr.lower()
    out: list[tuple[int, str, str]] = []
    for proc in psutil.process_iter(["pid", "name"]):
        try:
            pname = proc.info["name"] or ""
        except (psutil.NoSuchProcess, psutil.AccessDenied):
            continue
        if name_substr in pname.lower():
            hwnds = find_hwnds_for_pid(proc.info["pid"])
            title = hwnds[0][1] if hwnds else ""
            out.append((proc.info["pid"], pname, title))
    return out


def focus_hwnd(hwnd: int, settle: float = 0.15) -> None:
    """Bring ``hwnd`` to the foreground, working around SetForegroundWindow
    restrictions by temporarily attaching to the foreground thread's input."""
    if win32gui.IsIconic(hwnd):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)

    fg = win32gui.GetForegroundWindow()
    cur_thread = win32process.GetWindowThreadProcessId(fg)[0] if fg else 0
    tgt_thread = win32process.GetWindowThreadProcessId(hwnd)[0]

    attached = False
    try:
        if cur_thread and tgt_thread and cur_thread != tgt_thread:
            win32process.AttachThreadInput(cur_thread, tgt_thread, True)
            attached = True
        win32gui.BringWindowToTop(hwnd)
        win32gui.SetForegroundWindow(hwnd)
    except Exception:
        # Best-effort; some system/elevated windows will refuse focus.
        pass
    finally:
        if attached:
            try:
                win32process.AttachThreadInput(cur_thread, tgt_thread, False)
            except Exception:
                pass

    time.sleep(settle)


def focus_pid(pid: int, settle: float = 0.15) -> bool:
    """Focus the first visible window of ``pid``. Returns True on success."""
    if not psutil.pid_exists(pid):
        return False
    hwnds = find_hwnds_for_pid(pid)
    if not hwnds:
        return False
    focus_hwnd(hwnds[0][0], settle=settle)
    return True
