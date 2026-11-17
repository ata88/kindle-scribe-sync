"""One-time Amazon login in a real browser window, plus silent session refresh.

We keep a persistent browser profile. Amazon's long-lived "keep me signed in"
cookies live there, so when the short-lived session cookie expires, a headless
visit to Kindle for Web usually renews it without any user interaction.
"""

from __future__ import annotations

import json
import logging
import subprocess
import sys
import time
from typing import Any
from urllib.parse import urlparse

from .amazon import CookieStore
from .config import browser_profile_dir, cookies_path, home_dir
from .regions import REGIONS, Region, region_for_host

log = logging.getLogger(__name__)

API_PATH = "/kindle-notebook/api/notes"


class LoginError(Exception):
    pass


def _launch(p: Any, *, headless: bool) -> Any:
    profile = str(browser_profile_dir())
    args = ["--disable-blink-features=AutomationControlled"]
    try:  # the user's real Chrome looks least like a bot
        return p.chromium.launch_persistent_context(profile, channel="chrome", headless=headless, args=args,
                                                    viewport={"width": 520, "height": 860})
    except Exception:
        pass
    try:
        return p.chromium.launch_persistent_context(profile, headless=headless, args=args,
                                                    viewport={"width": 520, "height": 860})
    except Exception as e:
        if "Executable doesn't exist" not in str(e):
            raise
    print("Lade einmalig einen Browser für den Login herunter …")
    subprocess.run([sys.executable, "-m", "playwright", "install", "chromium"], check=True)
    return p.chromium.launch_persistent_context(profile, headless=headless, args=args,
                                                viewport={"width": 520, "height": 860})


def _api_status(ctx: Any, host: str) -> tuple[int, str, list[Any] | None]:
    """Ask the notebook API directly with the browser's cookies (no page parsing).

    Returns (http status, content-type, items or None).
    """
    try:
        r = ctx.request.get(f"https://{host}{API_PATH}", max_redirects=0, timeout=20000,
                            headers={"Accept": "application/json"})
        ctype = r.headers.get("content-type") or ""
        if r.status == 200 and "json" in ctype:
            data = r.json()
            if isinstance(data, dict) and "itemsList" in data:
                return r.status, ctype, data["itemsList"]
        return r.status, ctype, None
    except Exception as e:
        return 0, str(e)[:80], None


def _try_api(ctx: Any, host: str) -> list[Any] | None:
    return _api_status(ctx, host)[2]


def _logged_in_on(url: str) -> Region | None:
    """The browser is back on a Kindle-for-Web host and past the landing/sign-in pages."""
    u = urlparse(url)
    reg = region_for_host(u.hostname or "")
    if reg and not u.path.startswith(("/landing", "/ap/")):
        return reg
    return None


def _save(ctx: Any, page: Any, region: Region) -> None:
    cookies = [c for c in ctx.cookies() if "amazon" in c.get("domain", "")]
    ua = page.evaluate("navigator.userAgent").replace("HeadlessChrome", "Chrome")
    CookieStore(cookies_path()).save({"region": region.code, "user_agent": ua, "cookies": cookies,
                                      "saved_at": time.time()})


# Kindle-for-Web URL that reliably sends a signed-out browser to the Amazon
# sign-in page and back (lesen.amazon.de answers the API path with a 500
# instead of a redirect while signed out).
LOGIN_PATH = "/notebook"
_INTERESTING = ("notebook", "renderpage", "opennotebook", "karamel", "scribe")


def interactive_login(region_code: str, timeout: int = 900) -> tuple[Region, int]:
    """Open a browser, let the user sign in. Returns (region, number of top-level items)."""
    from playwright.sync_api import sync_playwright

    region = REGIONS[region_code]
    seen_requests: list[str] = []
    discovery = home_dir() / "discovered-requests.txt"

    def record(req: Any) -> None:
        url = req.url
        if any(k in url.lower() for k in _INTERESTING) and url not in seen_requests:
            seen_requests.append(url)
            with discovery.open("a", encoding="utf-8") as f:
                f.write(f"{req.method} {url}\n")

    with sync_playwright() as p:
        ctx = _launch(p, headless=False)
        ctx.on("request", record)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        page.goto(f"https://{region.read_host}{LOGIN_PATH}", wait_until="domcontentloaded")
        deadline = time.time() + timeout
        explained = False
        while time.time() < deadline:
            time.sleep(2.0)
            try:
                url = page.url
            except Exception:
                raise LoginError("Browserfenster wurde geschlossen")
            reg = region_for_host(urlparse(url).hostname or "")
            if reg is not None and reg.code != region.code:
                print(f"Amazon leitet auf {reg.read_host} um – verwende Region '{reg.code}'.")
                region = reg
            status, ctype, items = _api_status(ctx, region.read_host)
            if items is not None:
                _save(ctx, page, region)
                ctx.close()
                return region, len(items)
            if not explained and _logged_in_on(url):
                explained = True
                _save(ctx, page, region)  # keep the session for `kss doctor` either way
                print(f"\nAngemeldet bei {region.read_host}, aber die Notizbuch-API antwortet mit "
                      f"HTTP {status} ({ctype or 'kein Inhalt'}).\n"
                      "Bitte hilf mir, die richtige Adresse zu finden: Öffne im Browserfenster deine "
                      "Bibliothek / Notizbücher und klicke ein Scribe-Notizbuch an.\n"
                      f"Gefundene Anfragen landen in {discovery} – das Fenster bleibt offen, "
                      "bis die API antwortet oder du es schließt.\n")
        ctx.close()
    raise LoginError("Zeitüberschreitung beim Login")


def silent_refresh(region_code: str) -> bool:
    """Try to renew the session headlessly with the stored browser profile."""
    if not browser_profile_dir().exists():
        return False
    try:
        from playwright.sync_api import sync_playwright
    except ImportError:
        return False
    region = REGIONS[region_code]
    try:
        with sync_playwright() as p:
            ctx = _launch(p, headless=True)
            page = ctx.pages[0] if ctx.pages else ctx.new_page()
            page.goto(f"https://{region.read_host}{LOGIN_PATH}", wait_until="domcontentloaded", timeout=60000)
            time.sleep(2)
            ok = _try_api(ctx, region.read_host) is not None
            if ok:
                _save(ctx, page, region)
            ctx.close()
            return ok
    except Exception as e:  # never let a refresh attempt crash the sync
        log.warning("silent refresh failed: %s", e)
        return False
