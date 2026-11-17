"""Client for the (unofficial) Kindle for Web notebook API.

These are the endpoints the Kindle-for-Web notebook viewer uses:

  GET /kindle-notebook/api/notes                     -> folder/notebook tree
  GET /openNotebook?notebookId=..&marketplaceId=..   -> metadata + renderingToken
  GET /renderPage?startPage=..&endPage=..&width=..&height=..&dpi=..
      header x-amzn-karamel-notebook-rendering-token -> tar archive of PNG pages

Authentication is the normal Amazon web session (cookies), captured once with
`kss login`. Amazon can change these endpoints at any time.
"""

from __future__ import annotations

import io
import json
import logging
import re
import tarfile
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any
from urllib.parse import quote

import httpx

from .regions import REGIONS, Region

log = logging.getLogger(__name__)

DEFAULT_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"
)
PNG_MAGIC = b"\x89PNG\r\n\x1a\n"
TOKEN_HEADER = "x-amzn-karamel-notebook-rendering-token"
CHUNK = 3  # pages per renderPage request (same as the Kindle web viewer)


class AmazonError(Exception):
    pass


class AuthExpired(AmazonError):
    """The Amazon session is not (or no longer) valid -> run `kss login`."""


@dataclass
class Item:
    id: str
    title: str
    type: str  # "notebook" | "folder"
    folder_path: list[str] = field(default_factory=list)
    raw: dict[str, Any] = field(default_factory=dict)

    @property
    def hint_modified(self) -> str | None:
        """A modification marker if the list endpoint provides one."""
        for key in ("modificationTime", "lastModified", "lastModifiedTime", "updatedTime", "modifiedTime"):
            if key in self.raw and self.raw[key] not in (None, ""):
                return str(self.raw[key])
        return None


@dataclass
class NotebookMeta:
    title: str
    total_pages: int
    modification_time: str
    rendering_token: str
    raw: dict[str, Any] = field(default_factory=dict)


class CookieStore:
    """cookies.json: {"region": .., "user_agent": .., "cookies": [playwright-style dicts]}"""

    def __init__(self, path: Path):
        self.path = path

    def load(self) -> dict[str, Any]:
        if not self.path.exists():
            return {}
        return json.loads(self.path.read_text("utf-8"))

    def save(self, data: dict[str, Any]) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=1), "utf-8")
        tmp.chmod(0o600)
        tmp.replace(self.path)


class AmazonClient:
    def __init__(
        self,
        region: Region | str,
        cookie_store: CookieStore | None = None,
        *,
        base_url: str | None = None,
        request_delay: float = 0.4,
        timeout: float = 30.0,
    ):
        self.region = REGIONS[region] if isinstance(region, str) else region
        self.base_url = (base_url or f"https://{self.region.read_host}").rstrip("/")
        self.cookie_store = cookie_store
        self.request_delay = request_delay
        state = cookie_store.load() if cookie_store else {}
        self._state = state
        jar = httpx.Cookies()
        for c in state.get("cookies", []):
            jar.set(c["name"], c["value"], domain=c.get("domain", self.region.cookie_domain), path=c.get("path", "/"))
        self.http = httpx.Client(
            cookies=jar,
            timeout=timeout,
            follow_redirects=False,
            headers={
                "User-Agent": state.get("user_agent") or DEFAULT_UA,
                "Accept-Language": "de-DE,de;q=0.9,en;q=0.8",
            },
        )
        self._last_request = 0.0

    # -- plumbing ---------------------------------------------------------

    def close(self) -> None:
        self.persist_cookies()
        self.http.close()

    def __enter__(self) -> "AmazonClient":
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def persist_cookies(self) -> None:
        """Write refreshed cookies (Set-Cookie from Amazon) back to disk."""
        if not self.cookie_store or not self._state:
            return
        merged: dict[tuple[str, str, str], dict[str, Any]] = {}
        for c in self._state.get("cookies", []):
            merged[(c["name"], c.get("domain", ""), c.get("path", "/"))] = c
        for c in self.http.cookies.jar:
            key = (c.name, c.domain, c.path)
            old = merged.get(key, {})
            merged[key] = {
                **old,
                "name": c.name,
                "value": c.value or "",
                "domain": c.domain,
                "path": c.path,
                "expires": c.expires if c.expires is not None else old.get("expires", -1),
                "secure": bool(c.secure),
            }
        self._state["cookies"] = list(merged.values())
        self.cookie_store.save(self._state)

    def _throttle(self) -> None:
        wait = self.request_delay - (time.monotonic() - self._last_request)
        if wait > 0:
            time.sleep(wait)
        self._last_request = time.monotonic()

    def _get(self, path: str, *, headers: dict[str, str] | None = None, expect: str = "json",
             retries: int = 3) -> httpx.Response:
        self._throttle()
        url = path if path.startswith("http") else self.base_url + path
        for attempt in range(retries + 1):
            try:
                r = self.http.get(url, headers=headers)
            except httpx.TransportError as e:
                if attempt == retries:
                    raise AmazonError(f"network error: {e}") from e
                time.sleep(2 ** attempt)
                continue
            if r.status_code in (500, 502, 503, 504, 429) and attempt < retries:
                time.sleep(2 ** (attempt + 1))
                continue
            break
        if r.is_redirect:
            loc = r.headers.get("location", "")
            if "/ap/signin" in loc or "/ap/" in loc or "landing" in loc:
                raise AuthExpired("Amazon session expired (redirect to sign-in)")
            raise AmazonError(f"unexpected redirect to {loc}")
        if r.status_code == 401:
            raise AuthExpired("Amazon returned 401")
        if r.status_code == 403:
            raise AuthExpired("Amazon returned 403 (session invalid or token expired)")
        if r.status_code >= 400:
            raise AmazonError(f"HTTP {r.status_code} for {url}: {r.text[:200]}")
        if expect == "json" and "html" in r.headers.get("content-type", ""):
            raise AuthExpired("got an HTML page instead of JSON (probably the sign-in page)")
        return r

    # -- API --------------------------------------------------------------

    def list_items(self) -> list[Item]:
        """All notebooks (flattened), each with its folder path."""
        data = self._get("/kindle-notebook/api/notes").json()
        items = data.get("itemsList", data if isinstance(data, list) else [])
        out: list[Item] = []

        def walk(nodes: list[dict[str, Any]], path: list[str]) -> None:
            for n in nodes:
                kind = n.get("type", "notebook")
                title = (n.get("title") or "Unbenannt").strip()
                if kind == "folder":
                    walk(n.get("items") or [], path + [title])
                else:
                    raw = {k: v for k, v in n.items() if k != "items"}
                    out.append(Item(id=n["id"], title=title, type=kind, folder_path=path, raw=raw))
                    if n.get("items"):
                        walk(n["items"], path)

        walk(items, [])
        return out

    def _marketplace_candidates(self) -> list[str]:
        """The working marketplace first; an amazon.de account on read.amazon.com may need DE's id."""
        known = self._state.get("marketplace_id")
        order = [known, self.region.marketplace_id, REGIONS["de"].marketplace_id,
                 *(r.marketplace_id for r in REGIONS.values())]
        return list(dict.fromkeys(m for m in order if m))

    def open_notebook(self, notebook_id: str) -> NotebookMeta:
        last: Exception | None = None
        for mp in self._marketplace_candidates():
            try:
                probing = self._state.get("marketplace_id") != mp
                r = self._get(
                    f"/openNotebook?notebookId={quote(notebook_id, safe='')}&marketplaceId={mp}",
                    headers={"Accept": "application/json"},
                    retries=0 if probing else 3,
                )
                data = r.json()
            except AuthExpired as e:
                # 403 can also mean "wrong marketplace" here – but only if listing still works
                last = e
                if self._state.get("marketplace_id") == mp:
                    raise
                continue
            except (AmazonError, ValueError) as e:
                last = e
                continue
            token = data.get("renderingToken")
            if not token:
                last = AmazonError(f"openNotebook returned no renderingToken: {str(data)[:200]}")
                continue
            if self._state.get("marketplace_id") != mp:
                log.info("using marketplaceId %s", mp)
                self._state["marketplace_id"] = mp
                self.persist_cookies()
            meta = data.get("metadata", {})
            return NotebookMeta(
                title=meta.get("title", ""),
                total_pages=int(meta.get("totalPages", 0)),
                modification_time=str(meta.get("modificationTime", "")),
                rendering_token=token,
                raw=data,
            )
        assert last is not None
        raise last

    def render_range(self, token: str, start: int, end: int, *, width: int, height: int, dpi: int) -> list[bytes]:
        """Render pages start..end (inclusive). Returns PNGs in page order."""
        r = self._get(
            f"/renderPage?startPage={start}&endPage={end}&width={width}&height={height}&dpi={dpi}",
            headers={TOKEN_HEADER: token},
            expect="binary",
        )
        return extract_pngs(r.content)

    def render_notebook(
        self, notebook_id: str, *, width: int, height: int, dpi: int, meta: NotebookMeta | None = None
    ) -> tuple[NotebookMeta, list[bytes]]:
        meta = meta or self.open_notebook(notebook_id)
        total = meta.total_pages
        pages: dict[int, bytes] = {}
        token = meta.rendering_token
        for start in range(0, total, CHUNK):
            end = min(start + CHUNK - 1, total - 1)
            try:
                pngs = self.render_range(token, start, end, width=width, height=height, dpi=dpi)
            except AuthExpired:
                # rendering tokens are short-lived: reopen once, then give up
                meta = self.open_notebook(notebook_id)
                token = meta.rendering_token
                pngs = self.render_range(token, start, end, width=width, height=height, dpi=dpi)
            for k, png in enumerate(pngs[: end - start + 1]):
                pages[start + k] = png
        missing = [i for i in range(total) if i not in pages]
        for i in missing:  # fallback: one page at a time
            pngs = self.render_range(token, i, i, width=width, height=height, dpi=dpi)
            if pngs:
                pages[i] = pngs[0]
        if len(pages) != total:
            raise AmazonError(f"got {len(pages)} of {total} pages for notebook {notebook_id}")
        return meta, [pages[i] for i in range(total)]


_num = re.compile(r"(\d+)")


def _natural_key(name: str) -> list[Any]:
    return [int(t) if t.isdigit() else t for t in _num.split(name)]


def extract_pngs(blob: bytes) -> list[bytes]:
    """Pull PNG files out of the tar archive renderPage returns."""
    if blob.startswith(PNG_MAGIC):
        return [blob]
    found: list[tuple[str, bytes]] = []
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:*") as tar:
        for member in tar.getmembers():
            if not member.isfile() or "PaxHeaders" in member.name:
                continue
            if not member.name.lower().endswith(".png"):
                continue
            f = tar.extractfile(member)
            if f is None:
                continue
            data = f.read()
            off = data.find(PNG_MAGIC, 0, 1024 + len(PNG_MAGIC))
            if off >= 0:
                found.append((member.name, data[off:]))
    found.sort(key=lambda t: _natural_key(t[0]))
    return [d for _, d in found]
