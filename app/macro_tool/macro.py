"""Macro data model: JSON schema, load/save helpers.

A macro file looks like::

    {
      "name": "login-sequence",
      "created": "2026-08-17T10:00:00",
      "events": [
        {"t": 0.0,   "type": "mouse_move",  "x": 512, "y": 300},
        {"t": 0.12,  "type": "mouse_click", "button": "left",
                     "pressed": true, "x": 512, "y": 300},
        {"t": 0.5,   "type": "mouse_scroll", "x": 100, "y": 200,
                     "dx": 0, "dy": -1},
        {"t": 0.6,   "type": "key", "key": "a", "pressed": true},
        {"t": 0.66,  "type": "key", "key": "Key.enter", "pressed": false}
      ]
    }

``t`` is seconds elapsed since the recording started.
"""

from __future__ import annotations

import json
import os
from datetime import datetime

# Directory (relative to project root) where macros are stored.
MACROS_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "macros")

VALID_EVENT_TYPES = {"mouse_move", "mouse_click", "mouse_scroll", "key"}


def macro_path(name: str) -> str:
    """Return the JSON file path for a macro name."""
    if not name.endswith(".json"):
        name += ".json"
    return os.path.join(MACROS_DIR, name)


def ensure_macros_dir() -> None:
    os.makedirs(MACROS_DIR, exist_ok=True)


def save_macro(name: str, events: list[dict]) -> str:
    """Persist ``events`` under ``name`` and return the file path."""
    ensure_macros_dir()
    data = {
        "name": name,
        "created": datetime.now().isoformat(timespec="seconds"),
        "events": events,
    }
    path = macro_path(name)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2)
    return path


def load_macro(name: str) -> dict:
    """Load and lightly validate a macro file."""
    path = macro_path(name)
    if not os.path.exists(path):
        raise FileNotFoundError(f"Macro not found: {path}")
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)

    events = data.get("events")
    if not isinstance(events, list):
        raise ValueError(f"Malformed macro (no events list): {path}")
    for i, ev in enumerate(events):
        if ev.get("type") not in VALID_EVENT_TYPES:
            raise ValueError(f"Event {i} has invalid type: {ev.get('type')}")
    return data


def list_macros() -> list[str]:
    """Return names (without .json) of all stored macros."""
    if not os.path.isdir(MACROS_DIR):
        return []
    return sorted(
        f[:-5] for f in os.listdir(MACROS_DIR) if f.endswith(".json")
    )
