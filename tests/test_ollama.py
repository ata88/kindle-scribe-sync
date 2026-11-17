from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from fake_amazon import FakeAmazon, page_png


class FakeOllama:
    def __init__(self, models=("qwen3.5:9b",), thinking=True):
        self.models = set(models)
        self.thinking = thinking
        self.chats: list[dict] = []
        self.unloads: list[dict] = []
        self.hits = 0
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _out(self, code, obj):
                b = json.dumps(obj).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(b)))
                self.end_headers()
                self.wfile.write(b)

            def do_GET(self):
                fake.hits += 1
                self._out(200, {"version": "0.20.0"}) if self.path == "/api/version" else self._out(404, {})

            def do_POST(self):
                fake.hits += 1
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path == "/api/show":
                    return self._out(200 if body["model"] in fake.models else 404, {})
                if self.path == "/api/generate":
                    fake.unloads.append(body)
                    return self._out(200, {"done": True})
                if self.path == "/api/chat":
                    if "think" in body and not fake.thinking:
                        return self._out(400, {"error": f'"{body["model"]}" does not support thinking'})
                    fake.chats.append(body)
                    n = len(fake.chats)
                    return self._out(200, {"message": {"role": "assistant",
                                                       "content": f"<think>hmm</think>\n# Seite\nText {n}"}})
                self._out(404, {})

        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.srv.server_address[1]}"
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()


@pytest.fixture()
def setup(tmp_path, monkeypatch):
    monkeypatch.setenv("KSS_HOME", str(tmp_path / "home"))
    from kss.amazon import AmazonClient, CookieStore
    from kss.config import Config, cookies_path, db_path
    from kss.store import Store

    amazon_fake = FakeAmazon()
    CookieStore(cookies_path()).save({"region": "de", "cookies": []})
    amazon = AmazonClient("de", CookieStore(cookies_path()), base_url=amazon_fake.url, request_delay=0)
    yield amazon_fake, amazon, Store(db_path()), Config, tmp_path
    amazon.close()
    amazon_fake.stop()


def run_sync(cfg, store, amazon):
    from kss.cli import make_transcriber
    from kss.sync import Syncer

    return Syncer(cfg, store, amazon, lambda: make_transcriber(cfg), log_fn=lambda s: None).run()


def test_local_model_loaded_only_on_demand_and_unloaded(setup):
    amazon_fake, amazon, store, Config, tmp = setup
    ollama = FakeOllama()
    cfg = Config(ocr_backend="ollama", ollama_url=ollama.url, apple_notes=False, markdown_dir=str(tmp / "md"))
    amazon_fake.add("nb", "Tagebuch", [page_png("a"), page_png("b"), page_png("c")], mtime=1)

    run_sync(cfg, store, amazon)
    assert len(ollama.chats) == 3
    req = ollama.chats[0]
    assert req["model"] == "qwen3.5:9b" and req["stream"] is False and req["think"] is False
    assert req["options"]["temperature"] == 0 and req["keep_alive"] == "2m"
    assert req["messages"][1]["images"] and req["messages"][0]["role"] == "system"
    assert ollama.unloads == [{"model": "qwen3.5:9b", "keep_alive": 0}]  # evicted right after the pass
    assert store.page("nb", 0).transcript == "# Seite\nText 1"  # <think> stripped
    assert store.page("nb", 0).model == "qwen3.5:9b"

    # nothing new on the Scribe -> Ollama is not touched at all
    hits = ollama.hits
    run_sync(cfg, store, amazon)
    assert ollama.hits == hits and len(ollama.unloads) == 1


def test_model_without_thinking_switch(setup):
    amazon_fake, amazon, store, Config, tmp = setup
    ollama = FakeOllama(models=("gemma4:31b",), thinking=False)
    cfg = Config(ocr_backend="ollama", ollama_model="gemma4:31b", ollama_url=ollama.url,
                 apple_notes=False, markdown_dir="")
    amazon_fake.add("nb", "X", [page_png("a"), page_png("b")], mtime=1)
    run_sync(cfg, store, amazon)
    assert len(ollama.chats) == 2 and all("think" not in c for c in ollama.chats)
    assert store.notebook("nb").status == "done"


def test_missing_model_is_reported_not_crashing(setup):
    amazon_fake, amazon, store, Config, tmp = setup
    ollama = FakeOllama(models=())
    cfg = Config(ocr_backend="ollama", ollama_url=ollama.url, apple_notes=False, markdown_dir="")
    amazon_fake.add("nb", "X", [page_png("a")], mtime=1)
    rep = run_sync(cfg, store, amazon)
    assert rep.errors and "kss local-setup" in rep.errors[0]
    assert store.notebook("nb").status == "error"


def test_recommendation_by_ram():
    from kss.ocr_local import recommended_model

    assert recommended_model(64) == "gemma4:31b"
    assert recommended_model(36) == "gemma4:31b"
    assert recommended_model(24) == "qwen3.5:9b"
    assert recommended_model(16) == "qwen3.5:9b"
    assert recommended_model(8) == "qwen3-vl:4b"
