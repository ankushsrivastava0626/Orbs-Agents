#!/usr/bin/env python3
"""Custom-command orbs: if the model finished a turn without calling `speak`, read out its last reply.
Hook JSON (Stop) on stdin; prints the text to say, or nothing."""
import json, sys
try:
    hook = json.load(sys.stdin)
    lines = open(hook["transcript_path"], errors="ignore").read().splitlines()
except Exception:
    sys.exit(0)
spoke, text = False, ""
for raw in reversed(lines):                          # walk back to the start of this turn
    try: e = json.loads(raw)
    except Exception: continue
    if e.get("type") == "user" and not e.get("isMeta"):
        c = e.get("message", {}).get("content")
        if isinstance(c, str) or any(isinstance(b, dict) and b.get("type") == "text" for b in c or []):
            break                                    # your message: the turn began here
    if e.get("type") == "assistant":
        for b in e.get("message", {}).get("content") or []:
            if not isinstance(b, dict): continue
            if b.get("type") == "tool_use" and b.get("name", "").endswith("speak"): spoke = True
            if b.get("type") == "text" and b.get("text", "").strip() and not text: text = b["text"].strip()
if not spoke and text:
    print(text[:1500])
