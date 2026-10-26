#!/usr/bin/env python3
"""Fix a WAV whose header was never finished (recording cut off): 16 kHz mono 16-bit, data after 44 bytes."""
import os, struct, sys
for p in sys.argv[1:]:
    n = os.path.getsize(p) - 44
    if n <= 0: continue
    with open(p, "r+b") as f:
        f.seek(4); f.write(struct.pack("<I", 36 + n))
        f.seek(40); f.write(struct.pack("<I", n))
    print("repaired", p, f"{n / 32000 / 60:.1f} min")
