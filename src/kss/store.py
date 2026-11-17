"""SQLite state: which notebooks/pages we have, their hashes and transcripts."""

from __future__ import annotations

import json
import functools
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

SCHEMA = """
CREATE TABLE IF NOT EXISTS notebooks (
    id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    folder_path TEXT NOT NULL DEFAULT '[]',
    total_pages INTEGER NOT NULL DEFAULT 0,
    modification_time TEXT NOT NULL DEFAULT '',
    status TEXT NOT NULL DEFAULT 'new',      -- new | done | partial | error | deleted
    error TEXT,
    synced_at REAL,
    apple_note_id TEXT,
    markdown_file TEXT
);
CREATE TABLE IF NOT EXISTS pages (
    notebook_id TEXT NOT NULL,
    page_index INTEGER NOT NULL,
    image_hash TEXT NOT NULL,
    image_file TEXT NOT NULL,
    transcript TEXT,
    model TEXT,
    error TEXT,
    updated_at REAL,
    PRIMARY KEY (notebook_id, page_index)
);
"""


@dataclass
class NotebookRow:
    id: str
    title: str
    folder_path: list[str]
    total_pages: int
    modification_time: str
    status: str
    error: str | None
    synced_at: float | None
    apple_note_id: str | None
    markdown_file: str | None


@dataclass
class PageRow:
    notebook_id: str
    page_index: int
    image_hash: str
    image_file: str
    transcript: str | None
    model: str | None
    error: str | None
    updated_at: float | None


def _locked(fn):
    @functools.wraps(fn)
    def wrapper(self, *a, **kw):
        with self._lock:
            return fn(self, *a, **kw)
    return wrapper


class Store:
    """Thread-safe: OCR workers write pages concurrently through one connection."""

    def __init__(self, path: Path):
        self.path = path
        self._lock = threading.RLock()
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)
        self.db.commit()

    @_locked
    def close(self) -> None:
        self.db.close()

    # notebooks

    @_locked
    def notebook(self, nid: str) -> NotebookRow | None:
        r = self.db.execute("SELECT * FROM notebooks WHERE id=?", (nid,)).fetchone()
        return _nb(r) if r else None

    @_locked
    def notebooks(self, include_deleted: bool = False) -> list[NotebookRow]:
        q = "SELECT * FROM notebooks"
        if not include_deleted:
            q += " WHERE status != 'deleted'"
        q += " ORDER BY folder_path, title COLLATE NOCASE"
        return [_nb(r) for r in self.db.execute(q)]

    @_locked
    def upsert_notebook(self, nid: str, **fields: Any) -> None:
        if "folder_path" in fields:
            fields["folder_path"] = json.dumps(fields["folder_path"], ensure_ascii=False)
        existing = self.db.execute("SELECT 1 FROM notebooks WHERE id=?", (nid,)).fetchone()
        if existing:
            if fields:
                sets = ", ".join(f"{k}=?" for k in fields)
                self.db.execute(f"UPDATE notebooks SET {sets} WHERE id=?", (*fields.values(), nid))
        else:
            fields.setdefault("title", "Unbenannt")
            cols = ["id", *fields]
            self.db.execute(
                f"INSERT INTO notebooks ({', '.join(cols)}) VALUES ({', '.join('?' * len(cols))})",
                (nid, *fields.values()),
            )
        self.db.commit()

    # pages

    @_locked
    def pages(self, nid: str) -> list[PageRow]:
        rows = self.db.execute("SELECT * FROM pages WHERE notebook_id=? ORDER BY page_index", (nid,))
        return [PageRow(**dict(r)) for r in rows]

    @_locked
    def page(self, nid: str, idx: int) -> PageRow | None:
        r = self.db.execute("SELECT * FROM pages WHERE notebook_id=? AND page_index=?", (nid, idx)).fetchone()
        return PageRow(**dict(r)) if r else None

    @_locked
    def put_page(self, nid: str, idx: int, *, image_hash: str, image_file: str,
                 transcript: str | None, model: str | None, error: str | None) -> None:
        self.db.execute(
            """INSERT INTO pages (notebook_id, page_index, image_hash, image_file, transcript, model, error, updated_at)
               VALUES (?,?,?,?,?,?,?,?)
               ON CONFLICT(notebook_id, page_index) DO UPDATE SET
                 image_hash=excluded.image_hash, image_file=excluded.image_file,
                 transcript=excluded.transcript, model=excluded.model,
                 error=excluded.error, updated_at=excluded.updated_at""",
            (nid, idx, image_hash, image_file, transcript, model, error, time.time()),
        )
        self.db.commit()

    @_locked
    def trim_pages(self, nid: str, total: int) -> list[PageRow]:
        gone = [p for p in self.pages(nid) if p.page_index >= total]
        self.db.execute("DELETE FROM pages WHERE notebook_id=? AND page_index>=?", (nid, total))
        self.db.commit()
        return gone

    @_locked
    def search(self, q: str, limit: int = 50) -> list[tuple[NotebookRow, PageRow]]:
        like = f"%{q}%"
        rows = self.db.execute(
            """SELECT p.* FROM pages p JOIN notebooks n ON n.id = p.notebook_id
               WHERE n.status != 'deleted' AND (p.transcript LIKE ? OR n.title LIKE ?)
               ORDER BY n.title, p.page_index LIMIT ?""",
            (like, like, limit),
        ).fetchall()
        out = []
        for r in rows:
            page = PageRow(**dict(r))
            nb = self.notebook(page.notebook_id)
            if nb:
                out.append((nb, page))
        return out


def _nb(r: sqlite3.Row) -> NotebookRow:
    d = dict(r)
    d["folder_path"] = json.loads(d["folder_path"] or "[]")
    return NotebookRow(**d)
