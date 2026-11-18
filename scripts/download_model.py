#!/usr/bin/env python3
"""Download an MLX model snapshot from Hugging Face (used by CI for the recognition self-test).

usage: download_model.py REPO_ID TARGET_DIR
"""
import json
import os
import sys
import urllib.request

repo, target = sys.argv[1], sys.argv[2]
os.makedirs(target, exist_ok=True)
with urllib.request.urlopen(f"https://huggingface.co/api/models/{repo}?blobs=true") as r:
    files = [s["rfilename"] for s in json.load(r)["siblings"]]
for name in files:
    if name.startswith(".") or name.lower().endswith(".md"):
        continue
    dest = os.path.join(target, name)
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    print("download", name, flush=True)
    urllib.request.urlretrieve(f"https://huggingface.co/{repo}/resolve/main/{name}", dest)
open(os.path.join(target, ".complete"), "w").close()
print("done", target)
