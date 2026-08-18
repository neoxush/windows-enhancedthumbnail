"""Command-line interface for the macro tool.

Sub-commands:
    record   capture a new macro (F9 to stop)
    play     replay a macro against a PID with scheduling
    list     list saved macros
    pids     find PIDs (and window titles) by process name
"""

from __future__ import annotations

import argparse
import sys

from . import macro, window
from .recorder import Recorder
from .scheduler import run_scheduled


def cmd_record(args: argparse.Namespace) -> int:
    rec = Recorder(record_moves=not args.no_move)
    events = rec.record()
    if not events:
        print("No events captured; nothing saved.")
        return 1
    path = macro.save_macro(args.name, events)
    print(f"Saved {len(events)} events to {path}")
    return 0


def cmd_play(args: argparse.Namespace) -> int:
    try:
        data = macro.load_macro(args.name)
    except (FileNotFoundError, ValueError) as exc:
        print(f"[error] {exc}")
        return 1
    run_scheduled(
        data["events"],
        pid=args.pid,
        delay=args.delay,
        repeat=args.repeat,
        interval=args.interval,
        speed=args.speed,
        abort_key=args.abort_key,
    )
    return 0


def cmd_list(_: argparse.Namespace) -> int:
    names = macro.list_macros()
    if not names:
        print("No macros saved yet.")
        return 0
    print("Saved macros:")
    for n in names:
        print(f"  {n}")
    return 0


def cmd_pids(args: argparse.Namespace) -> int:
    matches = window.find_pids_by_name(args.name)
    if not matches:
        print(f"No processes matching '{args.name}'.")
        return 1
    print(f"{'PID':>8}  {'PROCESS':<25}  WINDOW TITLE")
    for pid, pname, title in matches:
        print(f"{pid:>8}  {pname:<25}  {title}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="macro_tool",
        description="Record, schedule and replay keyboard/mouse macros "
                    "against a target PID.",
    )
    sub = p.add_subparsers(dest="command", required=True)

    pr = sub.add_parser("record", help="record a new macro (F9 to stop)")
    pr.add_argument("--name", required=True, help="macro name")
    pr.add_argument("--no-move", action="store_true",
                    help="do not record mouse movement events")
    pr.set_defaults(func=cmd_record)

    pp = sub.add_parser("play", help="replay a macro against a PID")
    pp.add_argument("--name", required=True, help="macro name")
    pp.add_argument("--pid", type=int, required=True, help="target PID")
    pp.add_argument("--delay", type=float, default=0.0,
                    help="seconds to wait before the first run")
    pp.add_argument("--repeat", type=int, default=1,
                    help="number of runs (0 = infinite)")
    pp.add_argument("--interval", type=float, default=0.0,
                    help="seconds between runs")
    pp.add_argument("--speed", type=float, default=1.0,
                    help="playback speed multiplier (default 1.0)")
    pp.add_argument("--abort-key", default="esc",
                    help="pynput Key name to abort playback (default esc)")
    pp.set_defaults(func=cmd_play)

    pl = sub.add_parser("list", help="list saved macros")
    pl.set_defaults(func=cmd_list)

    pd = sub.add_parser("pids", help="find PIDs by process name")
    pd.add_argument("--name", required=True,
                    help="process name substring, e.g. notepad")
    pd.set_defaults(func=cmd_pids)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except KeyboardInterrupt:
        print("\nInterrupted.")
        return 130


if __name__ == "__main__":
    sys.exit(main())
