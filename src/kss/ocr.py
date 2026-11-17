"""Handwriting transcription with Claude (vision)."""

from __future__ import annotations

import base64
import io
import logging
import os
import subprocess
import sys
from typing import Protocol

import anthropic
from PIL import Image

log = logging.getLogger(__name__)

KEYCHAIN_SERVICE = "kindle-scribe-sync"
KEYCHAIN_ACCOUNT = "anthropic-api-key"

SYSTEM_PROMPT = """\
Du bist ein Experte für das Transkribieren handschriftlicher Notizen. Du bekommst
eine Seite aus einem Kindle-Scribe-Notizbuch (Graustufen-Scan, Stifteingabe) und
gibst den Inhalt als sauberes Markdown in Druckschrift zurück.

Regeln:
- Transkribiere wörtlich und vollständig, in der Originalsprache (meist {languages}).
  Nichts übersetzen, nichts zusammenfassen, keine Rechtschreibung "verbessern",
  außer offensichtlichen Buchstabendrehern beim Entziffern.
- Erhalte die Struktur: Überschriften (#, ##), Aufzählungen, nummerierte Listen,
  Einrückungen, Absätze. Checkboxen als "- [ ]" bzw. "- [x]".
  Pfeile als →, ←, ↔. Unterstrichene/umrahmte Wörter als **fett**.
- Tabellen als Markdown-Tabelle, Formeln in LaTeX ($...$).
- Zeichnungen, Skizzen oder Diagramme: eine kurze Zeile
  "> 🖼 Skizze: <knappe Beschreibung, inkl. Beschriftungen>" an der passenden Stelle.
- Unleserliche Stellen: dein bester Versuch mit [?] dahinter, z. B. "Projektplan[?]".
  Völlig unleserlich: [unleserlich].
- Durchgestrichener Text wird weggelassen.
- Leere Seite: gib exakt "(leere Seite)" zurück.
- Antworte NUR mit dem transkribierten Markdown – keine Einleitung, keine
  Kommentare, keine Code-Fences.
"""


class Transcriber(Protocol):
    model: str

    def transcribe(self, png: bytes, *, notebook_title: str, page_no: int, total: int,
                   previous_tail: str = "") -> str: ...


class TranscriptionError(Exception):
    pass


def resolve_api_key() -> str | None:
    """ANTHROPIC_API_KEY env var, else the macOS Keychain (set via `kss set-key`)."""
    if os.environ.get("ANTHROPIC_API_KEY"):
        return os.environ["ANTHROPIC_API_KEY"]
    if sys.platform == "darwin":
        try:
            out = subprocess.run(
                ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w"],
                capture_output=True, text=True, check=True,
            )
            return out.stdout.strip() or None
        except (subprocess.CalledProcessError, FileNotFoundError):
            return None
    return None


def store_api_key(key: str) -> None:
    if sys.platform != "darwin":
        raise RuntimeError("Keychain storage is macOS-only; set ANTHROPIC_API_KEY instead.")
    subprocess.run(
        ["security", "add-generic-password", "-U", "-s", KEYCHAIN_SERVICE, "-a", KEYCHAIN_ACCOUNT, "-w", key],
        check=True,
    )


def prepare_image(png: bytes, max_edge: int = 2000) -> tuple[str, str]:
    """Grayscale, flatten transparency, cap size. Returns (media_type, base64)."""
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
    return "image/png", base64.standard_b64encode(buf.getvalue()).decode("ascii")


class ClaudeTranscriber:
    def __init__(self, *, model: str = "claude-opus-5-5", effort: str = "medium",
                 languages: str = "Deutsch und Englisch", api_key: str | None = None):
        key = api_key or resolve_api_key()
        if not key:
            raise TranscriptionError(
                "Kein Anthropic API-Key gefunden. `kss set-key` ausführen oder ANTHROPIC_API_KEY setzen."
            )
        self.client = anthropic.Anthropic(api_key=key, max_retries=4)
        self.model = model
        self.effort = effort
        self.system = SYSTEM_PROMPT.format(languages=languages)

    def transcribe(self, png: bytes, *, notebook_title: str, page_no: int, total: int,
                   previous_tail: str = "") -> str:
        media_type, data = prepare_image(png)
        context = f'Notizbuch: "{notebook_title}", Seite {page_no} von {total}.'
        if previous_tail:
            context += (
                "\nZur Orientierung das Ende der vorherigen Seite (NICHT erneut ausgeben):\n"
                f"<vorherige_seite>\n{previous_tail}\n</vorherige_seite>"
            )
        try:
            response = self.client.beta.messages.create(
                model=self.model,
                max_tokens=16000,
                system=self.system,
                output_config={"effort": self.effort},
                # if a safety classifier declines, retry server-side on a fallback model
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
                messages=[{
                    "role": "user",
                    "content": [
                        {"type": "image", "source": {"type": "base64", "media_type": media_type, "data": data}},
                        {"type": "text", "text": context + "\n\nTranskribiere diese Seite."},
                    ],
                }],
            )
        except anthropic.AuthenticationError as e:
            raise TranscriptionError("Anthropic API-Key ungültig") from e
        except anthropic.RateLimitError as e:
            raise TranscriptionError("Anthropic Rate-Limit erreicht – nächster Sync versucht es erneut") from e
        except anthropic.APIStatusError as e:
            raise TranscriptionError(f"Anthropic API-Fehler {e.status_code}: {e.message}") from e
        except anthropic.APIConnectionError as e:
            raise TranscriptionError("Keine Verbindung zur Anthropic API") from e

        if response.stop_reason == "refusal":
            raise TranscriptionError("Transkription abgelehnt (refusal)")
        text = "".join(b.text for b in response.content if b.type == "text").strip()
        if response.stop_reason == "max_tokens":
            text += "\n\n[… abgeschnitten]"
        if text.startswith("```"):
            text = text.strip("`").removeprefix("markdown").strip()
        return text
