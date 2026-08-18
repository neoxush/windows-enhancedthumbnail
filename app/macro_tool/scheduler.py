"""Scheduling: initial delay + repeat count + interval, with PID re-focus."""

from __future__ import annotations

import time

from . import window
from .player import AbortListener, play_events


def _countdown(seconds: float, label: str) -> None:
    remaining = int(seconds)
    while remaining > 0:
        print(f"\r{label}: {remaining:>3}s ", end="", flush=True)
        time.sleep(1)
        remaining -= 1
    if seconds > 0:
        print("\r" + " " * 40 + "\r", end="", flush=True)


def run_scheduled(events: list[dict], pid: int, *, delay: float = 0.0,
                  repeat: int = 1, interval: float = 0.0, speed: float = 1.0,
                  abort_key: str = "esc") -> None:
    """Run ``events`` against ``pid``.

    repeat=0 means loop indefinitely (until abort key or Ctrl+C).
    Re-focuses the target window before each run.
    """
    pname = window.process_name(pid)
    if pname is None:
        print(f"[error] PID {pid} not found.")
        return
    print(f"Target: PID {pid} ({pname})")

    if delay > 0:
        _countdown(delay, "Starting in")

    run = 0
    with AbortListener(abort_key) as abort:
        while True:
            if abort.triggered.is_set():
                print("Aborted.")
                return
            if not window.focus_pid(pid):
                print(f"[error] Could not focus a window for PID {pid} "
                      f"(process may have exited). Stopping.")
                return

            run += 1
            tag = f"{run}/{repeat}" if repeat else f"{run}/inf"
            print(f"Run {tag}...")
            completed = play_events(events, speed=speed, abort=abort)
            if not completed:
                print("Aborted during playback.")
                return

            if repeat and run >= repeat:
                break
            if interval > 0:
                _countdown(interval, "Next run in")

    print("Done.")
