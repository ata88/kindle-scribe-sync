"""Local handwriting transcription with Ollama – loaded on demand, unloaded right after.

Memory lifecycle per sync pass:
  * no new pages      -> this class is never instantiated, nothing is loaded
  * new pages         -> model loads on the first page (keep_alive keeps it warm
                         between pages of the same pass)
  * end of the pass   -> close() sends keep_alive=0, the model leaves RAM at once.
                         If kss crashes, Ollama drops it after `keep_alive` anyway.
  * Ollama not running -> we start `ollama serve` ourselves and stop it afterwards.
"""

from __future__ import annotations

import base64
import io
import logging
import re
import shutil
import subprocess
import sys
import time

import httpx
from PIL import Image

from .ocr import SYSTEM_PROMPT, TranscriptionError

log = logging.getLogger(__name__)

_THINK = re.compile(r"<think>.*?</think>", re.S)

# Recommendation by unified memory (GB). Source: German handwriting CER test,
# taggedsync.com/blog/best-local-model-for-handwriting (Nov 2026).
RECOMMENDED = [
    (36, "gemma4:31b"),   # ~20 GB, best local accuracy on German handwriting
    (16, "qwen3.5:9b"),   # ~7 GB, very good, fast
    (0, "qwen3-vl:4b"),   # ~3 GB, for 8 GB Macs – noticeably weaker
]


def recommended_model(ram_gb: float) -> str:
    for min_gb, model in RECOMMENDED:
        if ram_gb >= min_gb:
            return model
    return RECOMMENDED[-1][1]


def system_ram_gb() -> float:
    try:
        if sys.platform == "darwin":
            out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, check=True)
            return int(out.stdout.strip()) / 1024**3
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    return int(line.split()[1]) / 1024**2
    except Exception:
        pass
    return 0.0


def prepare_image_local(png: bytes, max_edge: int = 1600) -> str:
    im = Image.open(io.BytesIO(png))
    if im.mode in ("RGBA", "LA", "P"):
        im = im.convert("RGBA")
        bg = Image.new("RGBA", im.size, (255, 255, 255, 255))
        bg.alpha_composite(im)
        im = bg
    im = im.convert("L")
    if max(im.size) > max_edge:
        im.thumbnail((max_edge, max_edge), Image.LANCZOS)
    buf = io.BytesIO()
    im.save(buf, format="PNG", optimize=True)
    return base64.b64encode(buf.getvalue()).decode("ascii")


class OllamaTranscriber:
    def __init__(self, *, model: str, url: str = "http://127.0.0.1:11434", languages: str = "Deutsch und Englisch",
                 num_ctx: int = 8192, keep_alive: str = "2m", start_server: bool = True,
                 timeout: float = 600.0):
        self.model = model
        self.url = url.rstrip("/")
        self.system = SYSTEM_PROMPT.format(languages=languages)
        self.num_ctx = num_ctx
        self.keep_alive = keep_alive
        self.http = httpx.Client(timeout=timeout)
        self._server: subprocess.Popen | None = None
        self._send_think = True
        self._used = False
        self._ensure_server(start_server)
        try:
            self._ensure_model()
        except BaseException:
            self._stop_server()
            self.http.close()
            raise

    # -- lifecycle -------------------------------------------------------

    def _alive(self) -> bool:
        try:
            return self.http.get(self.url + "/api/version", timeout=3).status_code == 200
        except httpx.HTTPError:
            return False

    def _ensure_server(self, start: bool) -> None:
        if self._alive():
            return
        exe = shutil.which("ollama") or ("/usr/local/bin/ollama" if sys.platform == "darwin" else None)
        if not start or not exe or not shutil.which(exe):
            raise TranscriptionError("Ollama läuft nicht. Installieren: https://ollama.com (oder `brew install ollama`)")
        log.info("starting ollama serve on demand")
        self._server = subprocess.Popen([exe, "serve"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                        start_new_session=True)
        for _ in range(60):
            time.sleep(0.5)
            if self._alive():
                return
        self._stop_server()
        raise TranscriptionError("Ollama-Server startet nicht")

    def _ensure_model(self) -> None:
        r = self.http.post(self.url + "/api/show", json={"model": self.model})
        if r.status_code == 404:
            raise TranscriptionError(f"Modell {self.model} fehlt – einmalig `kss local-setup` "
                                     f"oder `ollama pull {self.model}` ausführen")

    def close(self) -> None:
        """Evict the model from RAM now (and stop Ollama if we started it)."""
        try:
            if self._used:
                self.http.post(self.url + "/api/generate", json={"model": self.model, "keep_alive": 0}, timeout=30)
        except httpx.HTTPError as e:
            log.warning("could not unload %s: %s", self.model, e)
        finally:
            self._stop_server()
            self.http.close()

    def _stop_server(self) -> None:
        if self._server and self._server.poll() is None:
            self._server.terminate()
            try:
                self._server.wait(timeout=15)
            except subprocess.TimeoutExpired:
                self._server.kill()
        self._server = None

    # -- transcription ---------------------------------------------------

    def transcribe(self, png: bytes, *, notebook_title: str, page_no: int, total: int,
                   previous_tail: str = "") -> str:
        context = f'Notizbuch: "{notebook_title}", Seite {page_no} von {total}.'
        if previous_tail:
            context += ("\nZur Orientierung das Ende der vorherigen Seite (NICHT erneut ausgeben):\n"
                        f"<vorherige_seite>\n{previous_tail}\n</vorherige_seite>")
        body = {
            "model": self.model,
            "stream": False,
            "keep_alive": self.keep_alive,
            "options": {"temperature": 0, "seed": 0, "num_ctx": self.num_ctx, "num_predict": 4096},
            "messages": [
                {"role": "system", "content": self.system},
                {"role": "user", "content": context + "\n\nTranskribiere diese Seite.",
                 "images": [prepare_image_local(png)]},
            ],
        }
        if self._send_think:
            body["think"] = False  # thinking costs time and did not help handwriting in tests
        self._used = True
        try:
            r = self.http.post(self.url + "/api/chat", json=body)
            if r.status_code == 400 and "think" in r.text.lower() and self._send_think:
                self._send_think = False  # model has no thinking switch
                body.pop("think")
                r = self.http.post(self.url + "/api/chat", json=body)
        except httpx.HTTPError as e:
            raise TranscriptionError(f"Ollama nicht erreichbar: {e}") from e
        if r.status_code != 200:
            raise TranscriptionError(f"Ollama-Fehler {r.status_code}: {r.text[:200]}")
        text = _THINK.sub("", r.json().get("message", {}).get("content", "")).strip()
        if text.startswith("```"):
            text = text.strip("`").removeprefix("markdown").strip()
        if not text:
            raise TranscriptionError("Ollama lieferte keinen Text")
        return text


def pull_model(model: str, url: str = "http://127.0.0.1:11434") -> None:
    """Download a model with a simple progress line (used by `kss local-setup`)."""
    import json

    with httpx.Client(timeout=None) as http, http.stream("POST", url.rstrip("/") + "/api/pull",
                                                         json={"model": model, "stream": True}) as r:
        last = ""
        for line in r.iter_lines():
            if not line:
                continue
            ev = json.loads(line)
            if ev.get("error"):
                raise TranscriptionError(ev["error"])
            status = ev.get("status", "")
            if ev.get("total"):
                pct = 100 * ev.get("completed", 0) / ev["total"]
                msg = f"\r  {status[:30]:30s} {pct:5.1f}%"
            else:
                msg = f"\r  {status[:40]:40s}       "
            if msg != last:
                print(msg, end="", flush=True)
                last = msg
        print()
