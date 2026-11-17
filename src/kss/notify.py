"""macOS notifications (no-op elsewhere)."""

from __future__ import annotations

import subprocess
import sys


def notify(title: str, message: str, *, enabled: bool = True) -> None:
    if not enabled or sys.platform != "darwin":
        return
    script = 'on run argv\ndisplay notification (item 2 of argv) with title (item 1 of argv)\nend run'
    subprocess.run(["osascript", "-e", script, title, message], capture_output=True, timeout=20)
