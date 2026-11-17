"""Tiny local web app: browse notebooks, page image next to the transcript, search, copy."""

from __future__ import annotations

import json
import re
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from importlib import resources
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from .config import Config, db_path, pages_dir
from .store import Store

_IMG = re.compile(r"^/img/([A-Za-z0-9_\-]+/page-\d{4}\.png)$")
_NB = re.compile(r"^/api/notebooks/([^/]+)$")


def make_handler(store: Store, image_root: Path) -> type[BaseHTTPRequestHandler]:
    index_html = resources.files("kss").joinpath("static/index.html").read_bytes()

    class Handler(BaseHTTPRequestHandler):
        server_version = "kss"

        def log_message(self, fmt: str, *args: object) -> None:  # quiet
            pass

        def _send(self, body: bytes, ctype: str, status: int = 200, cache: bool = False) -> None:
            self.send_response(status)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "max-age=86400" if cache else "no-store")
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj: object, status: int = 200) -> None:
            self._send(json.dumps(obj, ensure_ascii=False).encode(), "application/json; charset=utf-8", status)

        def do_GET(self) -> None:
            u = urlparse(self.path)
            path = u.path
            if path in ("/", "/index.html"):
                return self._send(index_html, "text/html; charset=utf-8")
            if path == "/api/notebooks":
                return self._json([
                    {"id": n.id, "title": n.title, "folder": n.folder_path, "pages": n.total_pages,
                     "status": n.status, "synced_at": n.synced_at, "error": n.error}
                    for n in store.notebooks()
                ])
            m = _NB.match(path)
            if m:
                nb = store.notebook(m.group(1))
                if not nb:
                    return self._json({"error": "not found"}, 404)
                return self._json({
                    "id": nb.id, "title": nb.title, "folder": nb.folder_path, "status": nb.status,
                    "pages": [{"index": p.page_index, "image": f"/img/{p.image_file}?h={p.image_hash}",
                               "text": p.transcript, "error": p.error} for p in store.pages(nb.id)],
                })
            if path == "/api/search":
                q = (parse_qs(u.query).get("q") or [""])[0].strip()
                if len(q) < 2:
                    return self._json([])
                return self._json([
                    {"id": nb.id, "title": nb.title, "page": p.page_index, "snippet": _snippet(p.transcript or "", q)}
                    for nb, p in store.search(q)
                ])
            m = _IMG.match(path)
            if m:
                f = (image_root / m.group(1)).resolve()
                if image_root.resolve() in f.parents and f.exists():
                    return self._send(f.read_bytes(), "image/png", cache=True)
            self._send(b"not found", "text/plain", HTTPStatus.NOT_FOUND)

    return Handler


def _snippet(text: str, q: str, width: int = 70) -> str:
    i = text.lower().find(q.lower())
    if i < 0:
        return text[: width * 2]
    s = max(0, i - width)
    return ("…" if s else "") + text[s : i + len(q) + width] + "…"


def serve(cfg: Config) -> None:
    store = Store(db_path())
    httpd = ThreadingHTTPServer((cfg.web_host, cfg.web_port), make_handler(store, pages_dir()))
    print(f"Kindle Scribe Notizen: http://{cfg.web_host}:{cfg.web_port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
