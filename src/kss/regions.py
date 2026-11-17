"""Amazon marketplaces that serve Kindle for Web.

Kindle Scribe notebooks are served by read.amazon.com for every account: a
German account (Scribe bought on amazon.de) signs in there with the same
credentials. lesen.amazon.de has no notebook API (it answers with errors or
hangs), so "us" is the default and the other hosts are kept only as a fallback.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class Region:
    code: str
    read_host: str  # Kindle for Web host that serves the notebook API
    cookie_domain: str  # domain the session cookies are set on
    marketplace_id: str


REGIONS: dict[str, Region] = {
    r.code: r
    for r in [
        Region("us", "read.amazon.com", ".amazon.com", "ATVPDKIKX0DER"),
        Region("de", "lesen.amazon.de", ".amazon.de", "A1PA6795UKMFR9"),
        Region("uk", "read.amazon.co.uk", ".amazon.co.uk", "A1F83G8C2ARO7P"),
        Region("fr", "lire.amazon.fr", ".amazon.fr", "A13V1IB3VIYZZH"),
        Region("es", "leer.amazon.es", ".amazon.es", "A1RKKUPIHCS9HS"),
        Region("it", "leggi.amazon.it", ".amazon.it", "APJ6JRA9NG5V4"),
        Region("ca", "read.amazon.ca", ".amazon.ca", "A2EUQ1WTGCTBG2"),
        Region("au", "read.amazon.com.au", ".amazon.com.au", "A39IBJ37TRP1C6"),
        Region("jp", "read.amazon.co.jp", ".amazon.co.jp", "A1VC38T7YXB528"),
    ]
}

# Order in which `kss login --region auto` tries marketplaces.
AUTO_ORDER = ["us", "de", "uk", "fr", "es", "it", "ca", "au", "jp"]


def region_for_host(host: str) -> Region | None:
    host = host.lower().split(":")[0]
    for r in REGIONS.values():
        if host == r.read_host:
            return r
    return None
