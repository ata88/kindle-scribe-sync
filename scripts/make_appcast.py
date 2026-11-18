#!/usr/bin/env python3
"""Write a Sparkle appcast.xml for one release.

usage: make_appcast.py VERSION BUILD ZIP_URL LENGTH ED_SIGNATURE NOTES_MD OUT
"""
import html
import re
import sys
from email.utils import formatdate


def md_to_html(md: str) -> str:
    out, in_list = [], False
    for line in md.splitlines():
        t = line.strip()
        if re.match(r"^[-*] ", t):
            if not in_list:
                out.append("<ul>"); in_list = True
            out.append(f"<li>{html.escape(t[2:])}</li>")
            continue
        if in_list:
            out.append("</ul>"); in_list = False
        if t.startswith("#"):
            out.append(f"<h3>{html.escape(t.lstrip('#').strip())}</h3>")
        elif t:
            out.append(f"<p>{html.escape(t)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main() -> None:
    version, build, url, length, sig, notes_path, out = sys.argv[1:8]
    notes = open(notes_path, encoding="utf-8").read() if notes_path != "-" else ""
    xml = f"""<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Scribe Sync</title>
    <link>https://github.com/ata88/kindle-scribe-sync</link>
    <item>
      <title>Version {html.escape(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{html.escape(build)}</sparkle:version>
      <sparkle:shortVersionString>{html.escape(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <description><![CDATA[{md_to_html(notes)}]]></description>
      <enclosure url="{html.escape(url)}" length="{int(length)}" type="application/octet-stream" sparkle:edSignature="{html.escape(sig)}"/>
    </item>
  </channel>
</rss>
"""
    open(out, "w", encoding="utf-8").write(xml)


if __name__ == "__main__":
    main()
