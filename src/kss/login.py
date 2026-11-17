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
from .config import browser_profile_dir, cookies_path
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


def _try_api(ctx: Any, host: str) -> list[Any] | None:
    """Ask the notebook API directly with the browser's cookies (no page parsing)."""
    try:
        r = ctx.request.get(f"https://{host}{API_PATH}", max_redirects=0, timeout=20000,
                            headers={"Accept": "application/json"})
        if r.status != 200 or "json" not in (r.headers.get("content-type") or ""):
            return None
        data = r.json()
    except Exception:
        return None
    if isinstance(data, dict) and "itemsList" in data:
        return data["itemsList"]
    return None


def _save(ctx: Any, page: Any, region: Region) -> None:
    cookies = [c for c in ctx.cookies() if "amazon" in c.get("domain", "")]
    ua = page.evaluate("navigator.userAgent").replace("HeadlessChrome", "Chrome")
    CookieStore(cookies_path()).save({"region": region.code, "user_agent": ua, "cookies": cookies,
                                      "saved_at": time.time()})


def interactive_login(region_code: str, timeout: int = 900) -> tuple[Region, int]:
    """Open a browser, let the user sign in. Returns (region, number of top-level items)."""
    from playwright.sync_api import sync_playwright

    region = REGIONS[region_code]
    with sync_playwright() as p:
        ctx = _launch(p, headless=False)
        page = ctx.pages[0] if ctx.pages else ctx.new_page()
        target = f"https://{region.read_host}{API_PATH}"
        page.goto(target, wait_until="domcontentloaded")
        deadline = time.time() + timeout
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
            items = _try_api(ctx, region.read_host)
            if items is not None:
                _save(ctx, page, region)
                ctx.close()
                return region, len(items)
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
            page.goto(f"https://{region.read_host}{API_PATH}", wait_until="domcontentloaded", timeout=60000)
            time.sleep(2)
            ok = _try_api(ctx, region.read_host) is not None
            if ok:
                _save(ctx, page, region)
            ctx.close()
            return ok
    except Exception as e:  # never let a refresh attempt crash the sync
        log.warning("silent refresh failed: %s", e)
        return False
