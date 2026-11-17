"""A fake Kindle-for-Web notebook API, shaped like the real one."""

from __future__ import annotations

import io
import json
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from PIL import Image, ImageDraw


def page_png(label: str, w: int = 310, h: int = 438) -> bytes:
    im = Image.new("RGBA", (w, h), (255, 255, 255, 0))  # transparent like real renders may be
    d = ImageDraw.Draw(im)
    d.text((20, 20), label, fill=(0, 0, 0, 255))
    d.line((20, 60, w - 20, 60), fill=(0, 0, 0, 255), width=2)
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    return buf.getvalue()


def make_tar(pngs: list[bytes], prefix: bytes = b"") -> bytes:
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for i, png in enumerate(pngs):
            data = prefix + png
            info = tarfile.TarInfo(f"pages/{i}.png")
            info.size = len(data)
            info.pax_headers = {"comment": "x"}
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


class FakeAmazon:
    def __init__(self) -> None:
        # id -> {"title", "folder", "mtime", "pages": [png]}
        self.notebooks: dict[str, dict] = {}
        self.logged_in = True
        self.tokens: dict[str, str] = {}
        self.render_calls = 0
        self.open_calls = 0
        self._srv = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        self.url = f"http://127.0.0.1:{self._srv.server_address[1]}"
        threading.Thread(target=self._srv.serve_forever, daemon=True).start()

    def stop(self) -> None:
        self._srv.shutdown()

    def add(self, nid: str, title: str, pages: list[bytes], folder: str | None = None, mtime: int = 1) -> None:
        self.notebooks[nid] = {"title": title, "folder": folder, "mtime": mtime, "pages": pages}

    def tree(self) -> list[dict]:
        root: list[dict] = []
        folders: dict[str, dict] = {}
        for nid, nb in self.notebooks.items():
            node = {"id": nid, "title": nb["title"], "type": "notebook", "parentFolder": nb["folder"] or "root", "items": []}
            if nb["folder"]:
                f = folders.setdefault(nb["folder"], {"id": "f-" + nb["folder"], "title": nb["folder"],
                                                       "type": "folder", "items": []})
                if f not in root:
                    root.append(f)
                f["items"].append(node)
            else:
                root.append(node)
        return root

    def _handler(self):
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):  # noqa: D401
                pass

            def _out(self, code: int, body: bytes, ctype: str, headers: dict | None = None):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self):
                u = urlparse(self.path)
                q = {k: v[0] for k, v in parse_qs(u.query).items()}
                if not fake.logged_in:
                    return self._out(302, b"", "text/html", {"Location": "https://www.amazon.de/ap/signin?x=1"})
                if u.path == "/kindle-notebook/api/notes":
                    return self._out(200, json.dumps({"itemsList": fake.tree()}).encode(), "application/json",
                                     {"Set-Cookie": "session-token=refreshed; Path=/"})
                if u.path == "/openNotebook":
                    fake.open_calls += 1
                    nb = fake.notebooks.get(q.get("notebookId", ""))
                    if not nb:
                        return self._out(404, b"{}", "application/json")
                    token = f"tok-{q['notebookId']}-{fake.open_calls}"
                    fake.tokens[token] = q["notebookId"]
                    meta = {"currentPage": 0, "modificationTime": nb["mtime"], "title": nb["title"],
                            "totalPages": len(nb["pages"])}
                    return self._out(200, json.dumps({"metadata": meta, "readingSessionId": "rs",
                                                      "renderingToken": token}).encode(), "application/json")
                if u.path == "/renderPage":
                    fake.render_calls += 1
                    nid = fake.tokens.get(self.headers.get("x-amzn-karamel-notebook-rendering-token", ""))
                    if not nid:
                        return self._out(403, b"", "text/plain")
                    pages = fake.notebooks[nid]["pages"]
                    s, e = int(q["startPage"]), int(q["endPage"])
                    return self._out(200, make_tar(pages[s : e + 1], prefix=b"\x00\x01"), "application/x-tar")
                self._out(404, b"", "text/plain")

        return H
