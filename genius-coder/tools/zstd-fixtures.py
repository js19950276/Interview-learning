#!/usr/bin/env python3
"""Generate zstd round-trip fixtures for ZstdTests.

CPython 3.14 ships compression.zstd; the Swift decoder (via the linked
libzstd) must reproduce the original bytes exactly. Includes the real dsh
session log when present. Usage: python3 tools/zstd-fixtures.py [outdir]
"""
import json, hashlib, os, random, string, sys
from compression import zstd

out = sys.argv[1] if len(sys.argv) > 1 else "/tmp/gc-zstd-fixtures"
os.makedirs(out, exist_ok=True)
random.seed(20261029)
manifest = []

def add(name, data, level):
    comp = zstd.compress(data, level=level)
    open(f"{out}/{name}.zst", "wb").write(comp)
    open(f"{out}/{name}.orig", "wb").write(data)
    manifest.append({"name": name, "level": level, "origSize": len(data),
                     "sha": hashlib.sha256(data).hexdigest(), "compSize": len(comp)})

add("tiny", b"hello world hello world hello!\n", 1)
add("rle", b"a" * 5000, 1)
lines = [json.dumps({"type": "command/run", "seq": str(i), "data": {"x": "y" * random.randint(1, 30)}}) for i in range(200)]
add("jsonl-small", ("\n".join(lines) + "\n").encode(), 3)
text = " ".join(random.choices(string.ascii_lowercase + " ", k=60000)).encode()
add("text-medium", text, 3)
add("text-medium-high", text, 19)
add("big-multiblock", ("\n".join(lines) + "\n").encode() * 40, 3)
add("random", bytes(random.getrandbits(8) for _ in range(30000)), 1)
add("byte-cycle", bytes(range(256)) * 400, 9)

real = os.path.expanduser("~/.dsh/sessions")
found = None
for root, dirs, files in os.walk(real):
    for f in files:
        if f == "session.v4.jsonl.zstd":
            found = os.path.join(root, f)
            break
if found:
    data = zstd.ZstdFile(found).read()
    open(f"{out}/real-dsh.orig", "wb").write(data)
    import shutil
    shutil.copyfile(found, f"{out}/real-dsh.zst")
    manifest.append({"name": "real-dsh", "level": -1, "origSize": len(data),
                     "sha": hashlib.sha256(data).hexdigest(),
                     "source": found, "compSize": os.path.getsize(found)})

json.dump(manifest, open(f"{out}/manifest.json", "w"), indent=1)
print(f"wrote {len(manifest)} fixtures to {out}")
