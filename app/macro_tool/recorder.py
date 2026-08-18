"""Record keyboard and mouse actions into a macro event list.

Press F9 to stop recording.
"""

from __future__ import annotations

import time

from pynput import keyboard, mouse

# Throttle mouse-move sampling to avoid huge files.
_MOVE_MIN_INTERVAL = 1.0 / 30.0  # ~30 Hz

STOP_KEY = keyboard.Key.f9


class Recorder:
    def __init__(self, record_moves: bool = True):
        self.record_moves = record_moves
        self.events: list[dict] = []
        self._start: float | None = None
        self._last_move = 0.0
        self._stop = False
        self._m_listener: mouse.Listener | None = None
        self._k_listener: keyboard.Listener | None = None

    # -- timing -----------------------------------------------------------
    def _now(self) -> float:
        if self._start is None:
            self._start = time.perf_counter()
        return time.perf_counter() - self._start

    # -- mouse callbacks --------------------------------------------------
    def _on_move(self, x, y):
        if not self.record_moves:
            return
        t = self._now()
        if t - self._last_move < _MOVE_MIN_INTERVAL:
            return
        self._last_move = t
        self.events.append({"t": round(t, 4), "type": "mouse_move",
                            "x": int(x), "y": int(y)})

    def _on_click(self, x, y, button, pressed):
        self.events.append({
            "t": round(self._now(), 4), "type": "mouse_click",
            "button": button.name, "pressed": bool(pressed),
            "x": int(x), "y": int(y),
        })

    def _on_scroll(self, x, y, dx, dy):
        self.events.append({
            "t": round(self._now(), 4), "type": "mouse_scroll",
            "x": int(x), "y": int(y), "dx": int(dx), "dy": int(dy),
        })

    # -- keyboard callbacks ----------------------------------------------
    def _key_str(self, key) -> str:
        if isinstance(key, keyboard.KeyCode) and key.char is not None:
            return key.char
        return str(key)  # e.g. "Key.enter"

    def _on_press(self, key):
        if key == STOP_KEY:
            self._stop = True
            return False  # stops keyboard listener
        self.events.append({
            "t": round(self._now(), 4), "type": "key",
            "key": self._key_str(key), "pressed": True,
        })

    def _on_release(self, key):
        if key == STOP_KEY:
            return
        self.events.append({
            "t": round(self._now(), 4), "type": "key",
            "key": self._key_str(key), "pressed": False,
        })

    # -- run --------------------------------------------------------------
    def record(self) -> list[dict]:
        print("Recording... press F9 to stop.")
        self._m_listener = mouse.Listener(
            on_move=self._on_move,
            on_click=self._on_click,
            on_scroll=self._on_scroll,
        )
        self._k_listener = keyboard.Listener(
            on_press=self._on_press,
            on_release=self._on_release,
        )
        self._m_listener.start()
        self._k_listener.start()
        self._k_listener.join()  # blocks until F9
        self._m_listener.stop()
        print(f"Recording stopped. Captured {len(self.events)} events.")
        return self.events
