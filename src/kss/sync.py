"""One sync pass: Amazon -> changed pages -> Claude -> Apple Notes / Markdown."""

from __future__ import annotations

import fcntl
import hashlib
import io
import logging
import os
import time
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from PIL import Image

from . import apple_notes
from .amazon import AmazonClient, AuthExpired, Item
from .config import Config, home_dir, pages_dir
from .ocr import Transcriber, TranscriptionError
from .render import notebook_html, notebook_markdown, safe_filename
from .store import NotebookRow, Store

log = logging.getLogger(__name__)


@dataclass
class SyncReport:
    checked: int = 0
    updated: list[str] = field(default_factory=list)  # notebook titles
    pages_transcribed: int = 0
    errors: list[str] = field(default_factory=list)
    deleted: list[str] = field(default_factory=list)


class SyncLocked(Exception):
    pass


class _Lock:
    def __init__(self, path: Path):
        self.path = path
        self.fd: int | None = None

    def __enter__(self) -> "_Lock":
        self.fd = os.open(self.path, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(self.fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as e:
            os.close(self.fd)
            raise SyncLocked("Ein anderer Sync läuft gerade") from e
        return self

    def __exit__(self, *exc: object) -> None:
        if self.fd is not None:
            fcntl.flock(self.fd, fcntl.LOCK_UN)
            os.close(self.fd)


def pixel_hash(png: bytes) -> str:
    """Hash of the decoded pixels, so re-encoded but identical pages match."""
    im = Image.open(io.BytesIO(png)).convert("L")
    h = hashlib.sha256()
    h.update(f"{im.width}x{im.height}".encode())
    h.update(im.tobytes())
    return h.hexdigest()[:32]


class Syncer:
    def __init__(self, cfg: Config, store: Store, amazon: AmazonClient,
                 transcriber_factory: Callable[[], Transcriber], *,
                 log_fn: Callable[[str], None] = print):
        self.cfg = cfg
        self.store = store
        self.amazon = amazon
        self._transcriber_factory = transcriber_factory
        self._transcriber: Transcriber | None = None
        self.say = log_fn

    @property
    def transcriber(self) -> Transcriber:
        if self._transcriber is None:
            self._transcriber = self._transcriber_factory()
        return self._transcriber

    def run(self, *, force: bool = False, only: str | None = None) -> SyncReport:
        with _Lock(home_dir() / "sync.lock"):
            return self._run(force=force, only=only)

    def _run(self, *, force: bool, only: str | None) -> SyncReport:
        rep = SyncReport()
        items = self.amazon.list_items()  # AuthExpired propagates to the caller
        seen = set()
        for item in items:
            seen.add(item.id)
            if only and only not in (item.id, item.title):
                continue
            rep.checked += 1
            try:
                changed = self._sync_notebook(item, force=force, rep=rep)
                if changed:
                    rep.updated.append(item.title)
            except AuthExpired:
                raise
            except Exception as e:  # keep going with the other notebooks
                log.exception("notebook %s failed", item.title)
                rep.errors.append(f"{item.title}: {e}")
                self.store.upsert_notebook(item.id, title=item.title, folder_path=item.folder_path,
                                           status="error", error=str(e))
        if not only:
            for nb in self.store.notebooks():
                if nb.id not in seen:
                    self._mark_deleted(nb)
                    rep.deleted.append(nb.title)
        return rep

    # -- per notebook -----------------------------------------------------

    def _sync_notebook(self, item: Item, *, force: bool, rep: SyncReport) -> bool:
        row = self.store.notebook(item.id)
        moved = row is not None and (row.title != item.title or row.folder_path != item.folder_path)

        # cheap path: list endpoint already tells us nothing changed
        hint = item.hint_modified
        if (not force and row and row.status == "done" and hint and hint == row.modification_time
                and not moved):
            return False

        meta = self.amazon.open_notebook(item.id)
        mtime = hint or meta.modification_time
        if (not force and row and row.status == "done" and row.modification_time == mtime
                and row.total_pages == meta.total_pages):
            if moved:  # renamed/moved on the Scribe: refresh outputs only
                self.store.upsert_notebook(item.id, title=item.title, folder_path=item.folder_path)
                self._publish(item.id)
                return True
            return False

        self.say(f"↻ {item.title}: {meta.total_pages} Seite(n) werden geladen …")
        self.store.upsert_notebook(item.id, title=item.title, folder_path=item.folder_path,
                                   total_pages=meta.total_pages, error=None)
        meta, pngs = self.amazon.render_notebook(
            item.id, width=self.cfg.render_width, height=self.cfg.render_height,
            dpi=self.cfg.render_dpi, meta=meta,
        )

        nb_dir = pages_dir() / safe_id(item.id)
        nb_dir.mkdir(parents=True, exist_ok=True)
        # transcripts we already paid for, by image hash (survives inserted/reordered pages)
        known = {p.image_hash: p for p in self.store.pages(item.id) if p.transcript and p.image_hash}
        todo: list[tuple[int, bytes, str, str]] = []
        for idx, png in enumerate(pngs):
            h = pixel_hash(png)
            rel = f"{safe_id(item.id)}/page-{idx + 1:04d}.png"
            old = self.store.page(item.id, idx)
            if old and old.image_hash == h and old.transcript and not force:
                continue
            (pages_dir() / rel).write_bytes(png)
            reuse = known.get(h)
            if reuse and not force:
                self.store.put_page(item.id, idx, image_hash=h, image_file=rel, transcript=reuse.transcript,
                                    model=reuse.model, error=None)
                continue
            todo.append((idx, png, h, rel))

        for gone in self.store.trim_pages(item.id, len(pngs)):
            (pages_dir() / gone.image_file).unlink(missing_ok=True)

        failures = self._transcribe(item, todo, total=len(pngs)) if todo else 0
        rep.pages_transcribed += len(todo) - failures
        if failures:
            rep.errors.append(f"{item.title}: {failures} Seite(n) nicht transkribiert")

        self.store.upsert_notebook(
            item.id, title=item.title, folder_path=item.folder_path, total_pages=len(pngs),
            modification_time=mtime, status="partial" if failures else "done", synced_at=time.time(),
            error=f"{failures} Seite(n) fehlgeschlagen" if failures else None,
        )
        self._publish(item.id)
        self.say(f"✓ {item.title}: {len(todo) - failures} Seite(n) neu transkribiert")
        return bool(todo) or moved or row is None

    def _transcribe(self, item: Item, todo: list[tuple[int, bytes, str, str]], *, total: int) -> int:
        transcriber = self.transcriber

        def work(job: tuple[int, bytes, str, str]) -> bool:
            idx, png, h, rel = job
            prev = self.store.page(item.id, idx - 1) if idx > 0 else None
            tail = (prev.transcript or "")[-400:] if prev else ""
            try:
                text = transcriber.transcribe(png, notebook_title=item.title, page_no=idx + 1,
                                              total=total, previous_tail=tail)
                self.store.put_page(item.id, idx, image_hash=h, image_file=rel, transcript=text,
                                    model=transcriber.model, error=None)
                return True
            except TranscriptionError as e:
                log.warning("page %s/%d: %s", item.title, idx + 1, e)
                # keep hash empty so the page is retried next time
                self.store.put_page(item.id, idx, image_hash="", image_file=rel, transcript=None,
                                    model=None, error=str(e))
                return False

        with ThreadPoolExecutor(max_workers=max(1, self.cfg.ocr_concurrency)) as pool:
            results = list(pool.map(work, todo))
        return results.count(False)

    # -- outputs ----------------------------------------------------------

    def _publish(self, nid: str) -> None:
        nb = self.store.notebook(nid)
        assert nb is not None
        pages = self.store.pages(nid)
        if self.cfg.markdown_path:
            self._write_markdown(nb, pages)
        if self.cfg.apple_notes and apple_notes.available():
            body = notebook_html(nb, pages, embed_images=self.cfg.apple_notes_images, image_root=pages_dir())
            folder = apple_notes.folder_path_text(self.cfg.apple_notes_folder, nb.folder_path)
            note_id = apple_notes.upsert(body, note_id=nb.apple_note_id,
                                         account=self.cfg.apple_notes_account, folder_path=folder)
            if note_id and note_id != nb.apple_note_id:
                self.store.upsert_notebook(nid, apple_note_id=note_id)

    def _write_markdown(self, nb: NotebookRow, pages: list) -> None:
        root = self.cfg.markdown_path
        assert root is not None
        target = root.joinpath(*[safe_filename(p) for p in nb.folder_path], safe_filename(nb.title) + ".md")
        target.parent.mkdir(parents=True, exist_ok=True)
        tmp = target.with_suffix(".md.tmp")
        tmp.write_text(notebook_markdown(nb, pages), "utf-8")
        tmp.replace(target)
        rel = str(target.relative_to(root))
        if nb.markdown_file and nb.markdown_file != rel:
            (root / nb.markdown_file).unlink(missing_ok=True)
        self.store.upsert_notebook(nb.id, markdown_file=rel)

    def _mark_deleted(self, nb: NotebookRow) -> None:
        self.say(f"🗑 {nb.title} existiert nicht mehr auf dem Scribe")
        self.store.upsert_notebook(nb.id, status="deleted")
        # Intentionally keep Apple Note and Markdown file: deleting on the
        # Scribe should never silently destroy your only transcribed copy.


def safe_id(nid: str) -> str:
    return "".join(ch if ch.isalnum() or ch in "-_" else "_" for ch in nid)
