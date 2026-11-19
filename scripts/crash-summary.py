#!/usr/bin/env python3
"""Print the essentials of a macOS .ips crash report: exception, message and the crashing thread."""
import json, sys

text = open(sys.argv[1], encoding="utf-8", errors="replace").read()
header, _, body = text.partition("\n")
report = json.loads(body)
exc = report.get("exception", {})
print("exception:", exc.get("type"), exc.get("signal"), exc.get("subtype", ""))
print("keys:", ", ".join(report.keys()))
for key in ("asi", "termination", "exceptionReason", "ktriageinfo"):
    if key in report:
        print(key + ":", json.dumps(report[key])[:2500])
def find_strings(obj, path=""):
    if isinstance(obj, dict):
        for k, v in obj.items(): yield from find_strings(v, path + "/" + k)
    elif isinstance(obj, list):
        for i, v in enumerate(obj): yield from find_strings(v, path + f"[{i}]")
    elif isinstance(obj, str) and any(w in obj.lower() for w in ("exception", "reason", "layout pass")):
        yield path, obj
for path, val in list(find_strings(report))[:10]:
    print("text", path, ":", val[:1500])
images = report.get("usedImages", [])
for t in report.get("threads", []):
    if not t.get("triggered"):
        continue
    print("crashing thread:", t.get("name", ""), t.get("queue", ""))
    for f in t.get("frames", [])[:40]:
        img = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex", -1) < len(images) else "?"
        sym = f.get("symbol", "?")
        loc = f" {f['sourceFile']}:{f.get('sourceLine')}" if "sourceFile" in f else ""
        print(f"  {img:28} {sym}{loc}")
