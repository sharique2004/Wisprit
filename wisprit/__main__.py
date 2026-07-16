"""Wisprit entry point.

    python -m wisprit           # run the menu-bar app
    python -m wisprit doctor    # environment / permission check
    python -m wisprit hotkey    # print hotkey events (tap test)
    python -m wisprit insert …  # insert text into the focused app (test)
"""

from __future__ import annotations

import sys


def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else None

    if cmd == "doctor":
        from wisprit import doctor
        return doctor.run()

    if cmd == "hotkey":
        from wisprit.hotkey import _main as hotkey_main
        return hotkey_main()

    if cmd == "insert":
        from wisprit.insert import _main as insert_main
        return insert_main(argv[1:])

    if cmd in (None, "run", "app"):
        from wisprit.app import main as app_main
        return app_main()

    print(__doc__)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
