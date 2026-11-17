"""Install/remove macOS launchd agents: periodic sync + always-on web app."""

from __future__ import annotations

import os
import plistlib
import subprocess
import sys
from pathlib import Path

from .config import Config, home_dir, log_dir

SYNC_LABEL = "com.github.kindle-scribe-sync.sync"
WEB_LABEL = "com.github.kindle-scribe-sync.web"


def _agents_dir() -> Path:
    d = Path.home() / "Library" / "LaunchAgents"
    d.mkdir(parents=True, exist_ok=True)
    return d


def _plist(label: str, args: list[str], *, interval: int | None, keepalive: bool) -> dict:
    d: dict = {
        "Label": label,
        "ProgramArguments": [sys.executable, "-m", "kss", *args],
        "RunAtLoad": True,
        "StandardOutPath": str(log_dir() / f"{label.rsplit('.', 1)[-1]}.out.log"),
        "StandardErrorPath": str(log_dir() / f"{label.rsplit('.', 1)[-1]}.err.log"),
        "EnvironmentVariables": {
            "KSS_HOME": str(home_dir()),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
            "PYTHONUNBUFFERED": "1",
        },
        "ProcessType": "Background",
    }
    if interval:
        d["StartInterval"] = interval
    if keepalive:
        d["KeepAlive"] = True
    return d


def _load(label: str, path: Path) -> None:
    uid = os.getuid()
    subprocess.run(["launchctl", "bootout", f"gui/{uid}/{label}"], capture_output=True)
    subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", str(path)], check=True)


def install(cfg: Config, *, web: bool = True) -> list[Path]:
    if sys.platform != "darwin":
        raise RuntimeError("launchd gibt es nur auf macOS (auf einem Server: systemd-Timer, siehe README)")
    written = []
    jobs = [(SYNC_LABEL, ["sync", "--quiet"], cfg.poll_interval, False)]
    if web:
        jobs.append((WEB_LABEL, ["serve"], None, True))
    for label, args, interval, keep in jobs:
        path = _agents_dir() / f"{label}.plist"
        with path.open("wb") as f:
            plistlib.dump(_plist(label, args, interval=interval, keepalive=keep), f)
        _load(label, path)
        written.append(path)
    return written


def uninstall() -> None:
    uid = os.getuid()
    for label in (SYNC_LABEL, WEB_LABEL):
        subprocess.run(["launchctl", "bootout", f"gui/{uid}/{label}"], capture_output=True)
        (_agents_dir() / f"{label}.plist").unlink(missing_ok=True)


def kick_sync() -> None:
    subprocess.run(["launchctl", "kickstart", f"gui/{os.getuid()}/{SYNC_LABEL}"], capture_output=True)
