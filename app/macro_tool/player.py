"""Replay recorded macro events via pynput controllers."""

from __future__ import annotations

import threading
import time

from pynput import keyboard, mouse

_mouse = mouse.Controller()
_keyboard = keyboard.Controller()

_BUTTONS = {
    "left": mouse.Button.left,
    "right": mouse.Button.right,
    "middle": mouse.Button.middle,
}


def _resolve_key(key_str: str):
    """Turn a serialized key string back into a pynput key object."""
    if key_str.startswith("Key."):
        name = key_str.split(".", 1)[1]
        try:
            return getattr(keyboard.Key, name)
        except AttributeError:
            return None
    return key_str  # a plain character


class AbortListener:
    """Global key listener that flips an event when the abort key is pressed."""

    def __init__(self, abort_key: str = "esc"):
        self._key = getattr(keyboard.Key, abort_key, keyboard.Key.esc)
        self.triggered = threading.Event()
        self._listener: keyboard.Listener | None = None

    def _on_press(self, key):
        if key == self._key:
            self.triggered.set()
            return False

    def __enter__(self):
        self._listener = keyboard.Listener(on_press=self._on_press)
        self._listener.start()
        return self

    def __exit__(self, *exc):
        if self._listener:
            self._listener.stop()


def play_events(events: list[dict], speed: float = 1.0,
                abort: AbortListener | None = None) -> bool:
    """Replay ``events`` honoring recorded timing (scaled by ``speed``).

    Returns False if aborted, True if it completed.
    """
    if speed <= 0:
        speed = 1.0

    start = time.perf_counter()
    for ev in events:
        if abort and abort.triggered.is_set():
            return False

        # Sleep until this event's scheduled time.
        target = ev.get("t", 0.0) / speed
        while True:
            elapsed = time.perf_counter() - start
            remaining = target - elapsed
            if remaining <= 0:
                break
            if abort and abort.triggered.is_set():
                return False
            time.sleep(min(remaining, 0.02))

        _dispatch(ev)

    return True


def _dispatch(ev: dict) -> None:
    etype = ev["type"]
    if etype == "mouse_move":
        _mouse.position = (ev["x"], ev["y"])
    elif etype == "mouse_click":
        _mouse.position = (ev["x"], ev["y"])
        btn = _BUTTONS.get(ev["button"], mouse.Button.left)
        if ev["pressed"]:
            _mouse.press(btn)
        else:
            _mouse.release(btn)
    elif etype == "mouse_scroll":
        _mouse.position = (ev["x"], ev["y"])
        _mouse.scroll(ev.get("dx", 0), ev.get("dy", 0))
    elif etype == "key":
        key = _resolve_key(ev["key"])
        if key is None:
            return
        if ev["pressed"]:
            _keyboard.press(key)
        else:
            _keyboard.release(key)
