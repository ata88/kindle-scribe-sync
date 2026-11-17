from __future__ import annotations

import json
import threading
import urllib.request
from http.server import ThreadingHTTPServer

import pytest

from fake_amazon import FakeAmazon, make_tar, page_png


@pytest.fixture()
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("KSS_HOME", str(tmp_path / "home"))
    from kss.amazon import AmazonClient, CookieStore
    from kss.config import Config, cookies_path, db_path
    from kss.store import Store

    fake = FakeAmazon()
    CookieStore(cookies_path()).save({"region": "de", "user_agent": "test", "cookies": [
        {"name": "session-token", "value": "abc", "domain": "127.0.0.1", "path": "/"}]})
    cfg = Config(apple_notes=False, markdown_dir=str(tmp_path / "md"), request_delay=0)
    store = Store(db_path())
    amazon = AmazonClient("de", CookieStore(cookies_path()), base_url=fake.url, request_delay=0)
    yield fake, cfg, store, amazon, tmp_path
    amazon.close()
    fake.stop()


class FakeOCR:
    model = "fake"

    def __init__(self, fail_on: set[int] | None = None):
        self.calls: list[tuple[str, int]] = []
        self.fail_on = fail_on or set()
        self.lock = threading.Lock()

    def transcribe(self, png, *, notebook_title, page_no, total, previous_tail=""):
        from kss.ocr import TranscriptionError

        with self.lock:
            self.calls.append((notebook_title, page_no))
        if page_no in self.fail_on:
            raise TranscriptionError("boom")
        return f"# {notebook_title}\n\nText von Seite {page_no}\n- [ ] Aufgabe"


def make_syncer(cfg, store, amazon, ocr):
    from kss.sync import Syncer

    return Syncer(cfg, store, amazon, lambda: ocr, log_fn=lambda s: None)


def test_full_flow(env):
    fake, cfg, store, amazon, tmp = env
    pages = [page_png(f"p{i}") for i in range(5)]
    fake.add("nb1", "Meeting Notizen", pages, folder="Arbeit", mtime=100)
    fake.add("nb2", "Ideen", [page_png("idee")], mtime=5)

    ocr = FakeOCR()
    rep = make_syncer(cfg, store, amazon, ocr).run()
    assert sorted(rep.updated) == ["Ideen", "Meeting Notizen"]
    assert len(ocr.calls) == 6
    md = (tmp / "md" / "Arbeit" / "Meeting Notizen.md").read_text()
    assert "## Seite 5" in md and "Text von Seite 3" in md
    assert store.notebook("nb1").status == "done"
    assert store.notebook("nb1").folder_path == ["Arbeit"]

    # nothing changed -> no rendering, no AI calls
    renders = fake.render_calls
    rep = make_syncer(cfg, store, amazon, ocr).run()
    assert rep.updated == [] and len(ocr.calls) == 6 and fake.render_calls == renders

    # one page edited -> exactly one new AI call
    fake.notebooks["nb1"]["pages"][2] = page_png("p2 edited")
    fake.notebooks["nb1"]["mtime"] = 101
    rep = make_syncer(cfg, store, amazon, ocr).run()
    assert rep.updated == ["Meeting Notizen"]
    assert ocr.calls[6:] == [("Meeting Notizen", 3)]

    # page inserted at the front -> only the new page is transcribed (hash reuse)
    fake.notebooks["nb1"]["pages"].insert(0, page_png("new first"))
    fake.notebooks["nb1"]["mtime"] = 102
    make_syncer(cfg, store, amazon, ocr).run()
    assert ocr.calls[7:] == [("Meeting Notizen", 1)]
    assert len(store.pages("nb1")) == 6

    # page removed -> trimmed
    fake.notebooks["nb1"]["pages"].pop()
    fake.notebooks["nb1"]["mtime"] = 103
    make_syncer(cfg, store, amazon, ocr).run()
    assert len(store.pages("nb1")) == 5 and len(ocr.calls) == 8

    # rename + move on the Scribe -> markdown file moves, no AI calls
    fake.notebooks["nb2"]["title"] = "Ideen 2026"
    fake.notebooks["nb2"]["folder"] = "Privat"
    make_syncer(cfg, store, amazon, ocr).run()
    assert (tmp / "md" / "Privat" / "Ideen 2026.md").exists()
    assert not (tmp / "md" / "Ideen.md").exists()
    assert len(ocr.calls) == 8

    # deleted on the Scribe -> marked deleted, files kept
    del fake.notebooks["nb2"]
    rep = make_syncer(cfg, store, amazon, ocr).run()
    assert rep.deleted == ["Ideen 2026"]
    assert store.notebook("nb2").status == "deleted"
    assert (tmp / "md" / "Privat" / "Ideen 2026.md").exists()


def test_failed_pages_are_retried(env):
    fake, cfg, store, amazon, tmp = env
    fake.add("nb", "Test", [page_png("a"), page_png("b")], mtime=1)
    ocr = FakeOCR(fail_on={2})
    rep = make_syncer(cfg, store, amazon, ocr).run()
    assert store.notebook("nb").status == "partial"
    assert rep.errors
    ocr.fail_on = set()
    make_syncer(cfg, store, amazon, ocr).run()  # same mtime, but partial -> retry
    assert store.notebook("nb").status == "done"
    assert ocr.calls == [("Test", 1), ("Test", 2), ("Test", 2)]


def test_auth_expired(env):
    from kss.amazon import AuthExpired

    fake, cfg, store, amazon, tmp = env
    fake.logged_in = False
    with pytest.raises(AuthExpired):
        amazon.list_items()


def test_cookies_refreshed_and_persisted(env):
    from kss.config import cookies_path

    fake, cfg, store, amazon, tmp = env
    amazon.list_items()
    amazon.persist_cookies()
    saved = json.loads(cookies_path().read_text())
    assert any(c["name"] == "session-token" and c["value"] == "refreshed" for c in saved["cookies"])
    assert oct(cookies_path().stat().st_mode)[-3:] == "600"


def test_extract_pngs_handles_prefix_and_order():
    from kss.amazon import extract_pngs

    pngs = [page_png(str(i)) for i in range(12)]
    out = extract_pngs(make_tar(pngs, prefix=b"junk"))
    assert out == pngs  # natural sort: 2 before 10


def test_html_and_markdown_render(env):
    from kss.render import markdown_to_html, notebook_html
    from kss.store import NotebookRow, PageRow

    nb = NotebookRow("x", "Titel <&>", ["A"], 1, "1", "done", None, None, None, None)
    p = PageRow("x", 0, "h", "x/page-0001.png", "## Punkt\n- [ ] offen\n- [x] erledigt", "m", None, None)
    html = notebook_html(nb, [p], embed_images=False)
    assert html.startswith("<html><body><div><h1>Titel &lt;&amp;&gt;</h1>")
    assert "☐ offen" in html and "☑ erledigt" in html
    assert "<table>" in markdown_to_html("| a | b |\n|---|---|\n| 1 | 2 |")


def test_apple_notes_folder_text():
    from kss.apple_notes import folder_path_text

    assert folder_path_text("Kindle Scribe", ["Arbeit", "A/B"]) == "Kindle Scribe/Arbeit/A∕B"


def test_web_app(env):
    from kss.config import pages_dir
    from kss.web import make_handler

    fake, cfg, store, amazon, tmp = env
    fake.add("nb", "Einkauf", [page_png("milch")], mtime=1)
    make_syncer(cfg, store, amazon, FakeOCR()).run()
    srv = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(store, pages_dir()))
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{srv.server_address[1]}"
    try:
        assert b"Scribe Notizen" in urllib.request.urlopen(base + "/").read()
        nbs = json.loads(urllib.request.urlopen(base + "/api/notebooks").read())
        assert nbs[0]["title"] == "Einkauf"
        detail = json.loads(urllib.request.urlopen(base + "/api/notebooks/nb").read())
        img = urllib.request.urlopen(base + detail["pages"][0]["image"]).read()
        assert img.startswith(b"\x89PNG")
        hits = json.loads(urllib.request.urlopen(base + "/api/search?q=Seite%201").read())
        assert hits and hits[0]["id"] == "nb"
        with pytest.raises(urllib.error.HTTPError):
            urllib.request.urlopen(base + "/img/../../kss.sqlite3")
    finally:
        srv.shutdown()


def test_prepare_image_flattens_transparency():
    import base64
    import io

    from PIL import Image

    from kss.ocr import prepare_image

    mt, b64 = prepare_image(page_png("x", 3000, 4000))
    im = Image.open(io.BytesIO(base64.b64decode(b64)))
    assert mt == "image/png" and im.mode == "L" and max(im.size) == 2000
    assert im.getpixel((5, 5)) == 255  # transparent -> white, not black
