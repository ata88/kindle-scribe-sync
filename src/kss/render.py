"""Turn a notebook's page transcripts into Markdown / HTML documents."""

from __future__ import annotations

import base64
import html
import io
import re
from datetime import datetime
from pathlib import Path

import markdown as md
from PIL import Image

from .store import NotebookRow, PageRow

_CHECK_OPEN = re.compile(r"^(\s*)[-*] \[ \] ", re.M)
_CHECK_DONE = re.compile(r"^(\s*)[-*] \[[xX]\] ", re.M)


def notebook_markdown(nb: NotebookRow, pages: list[PageRow]) -> str:
    folder = " / ".join(nb.folder_path)
    lines = [
        "---",
        f"title: {_yaml(nb.title)}",
        f"kindle_notebook_id: {nb.id}",
        f"folder: {_yaml(folder)}",
        f"pages: {nb.total_pages}",
        f"synced: {datetime.now().isoformat(timespec='seconds')}",
        "source: kindle-scribe",
        "---",
        "",
        f"# {nb.title}",
        "",
    ]
    for p in pages:
        lines.append(f"## Seite {p.page_index + 1}")
        lines.append("")
        lines.append(_page_text(p))
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def notebook_html(nb: NotebookRow, pages: list[PageRow], *, embed_images: bool,
                  image_root: Path | None = None) -> str:
    """HTML body for Apple Notes (first line = note title)."""
    parts = [f"<div><h1>{html.escape(nb.title)}</h1></div>"]
    if nb.folder_path:
        parts.append(f"<div><i>📁 {html.escape(' / '.join(nb.folder_path))}</i></div>")
    for p in pages:
        parts.append("<div><br></div>")
        parts.append(f"<div><h2>Seite {p.page_index + 1}</h2></div>")
        parts.append(markdown_to_html(_page_text(p)))
        if embed_images and image_root is not None:
            img = image_root / p.image_file
            if img.exists():
                parts.append(f'<div><img src="data:image/jpeg;base64,{_jpeg_b64(img)}"></div>')
    stamp = datetime.now().strftime("%d.%m.%Y %H:%M")
    parts.append("<div><br></div>")
    parts.append(
        f"<div><font color=\"#888888\"><small>Automatisch synchronisiert vom Kindle Scribe · {stamp} · "
        "Änderungen hier werden beim nächsten Sync überschrieben.</small></font></div>"
    )
    return "<html><body>" + "\n".join(parts) + "</body></html>"


def markdown_to_html(text: str) -> str:
    text = _CHECK_OPEN.sub(r"\1- ☐ ", text)
    text = _CHECK_DONE.sub(r"\1- ☑ ", text)
    return md.markdown(text, extensions=["tables", "sane_lists", "nl2br"])


def _page_text(p: PageRow) -> str:
    if p.transcript:
        return p.transcript.strip()
    if p.error:
        return f"*(Transkription fehlgeschlagen: {p.error} – wird beim nächsten Sync erneut versucht)*"
    return "*(noch nicht transkribiert)*"


def _jpeg_b64(path: Path, max_width: int = 900) -> str:
    im = Image.open(path).convert("L")
    if im.width > max_width:
        im.thumbnail((max_width, max_width * 2), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="JPEG", quality=72, optimize=True)
    return base64.b64encode(buf.getvalue()).decode("ascii")


def _yaml(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


_bad = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


def safe_filename(name: str) -> str:
    name = _bad.sub("-", name).strip(" .") or "Unbenannt"
    return name[:120]
