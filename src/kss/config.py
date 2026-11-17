"""Paths and user configuration."""

from __future__ import annotations

import os
import sys
from dataclasses import asdict, dataclass, fields
from pathlib import Path

if sys.version_info >= (3, 11):
    import tomllib
else:  # pragma: no cover
    import tomli as tomllib

APP = "kindle-scribe-sync"


def home_dir() -> Path:
    """Directory holding config, cookies, database and page images."""
    override = os.environ.get("KSS_HOME")
    if override:
        p = Path(override).expanduser()
    elif sys.platform == "darwin":
        p = Path.home() / "Library" / "Application Support" / APP
    else:
        p = Path(os.environ.get("XDG_DATA_HOME", Path.home() / ".local" / "share")) / APP
    p.mkdir(parents=True, exist_ok=True)
    return p


def config_path() -> Path:
    return home_dir() / "config.toml"


def cookies_path() -> Path:
    return home_dir() / "cookies.json"


def browser_profile_dir() -> Path:
    return home_dir() / "browser-profile"


def db_path() -> Path:
    return home_dir() / "kss.sqlite3"


def pages_dir() -> Path:
    p = home_dir() / "notebooks"
    p.mkdir(parents=True, exist_ok=True)
    return p


def log_dir() -> Path:
    p = home_dir() / "logs"
    p.mkdir(parents=True, exist_ok=True)
    return p


@dataclass
class Config:
    # Amazon
    region: str = "us"  # set by `kss login`
    poll_interval: int = 300  # seconds between syncs (launchd agent)
    request_delay: float = 0.4  # pause between Amazon requests, be gentle
    render_width: int = 1240  # requested page render size (px)
    render_height: int = 1754
    render_dpi: int = 150

    # AI transcription
    model: str = "claude-opus-5-5"
    effort: str = "medium"  # low | medium | high | xhigh | max
    language_hint: str = "Deutsch und Englisch"
    ocr_concurrency: int = 4

    # Apple Notes
    apple_notes: bool = True
    apple_notes_account: str = "iCloud"  # "" = default account
    apple_notes_folder: str = "Kindle Scribe"
    apple_notes_images: bool = True  # embed page images under the text

    # Markdown export (Obsidian etc.). "" disables it.
    markdown_dir: str = "~/Documents/Kindle Scribe"

    # Local web app
    web_host: str = "127.0.0.1"
    web_port: int = 8765

    # Notifications (macOS)
    notify: bool = True

    @classmethod
    def load(cls) -> "Config":
        cfg = cls()
        p = config_path()
        if p.exists():
            data = tomllib.loads(p.read_text("utf-8"))
            known = {f.name: f.type for f in fields(cls)}
            for k, v in data.items():
                if k in known:
                    setattr(cfg, k, v)
        return cfg

    def save(self) -> None:
        lines = ["# kindle-scribe-sync configuration", ""]
        for k, v in asdict(self).items():
            lines.append(f"{k} = {_toml_value(v)}")
        config_path().write_text("\n".join(lines) + "\n", "utf-8")

    @property
    def markdown_path(self) -> Path | None:
        return Path(self.markdown_dir).expanduser() if self.markdown_dir else None


def _toml_value(v: object) -> str:
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    s = str(v).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{s}"'
