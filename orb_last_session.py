import json, os, re, sys
try: orbs = json.load(open(sys.argv[1]))
except Exception: orbs = []
o = next((o for o in orbs if o.get("name") == sys.argv[2] and o.get("kind") == "claude"), None)
if o and o.get("id"):
    t = os.path.expanduser("~/.claude/projects/" + re.sub(r"[^A-Za-z0-9]", "-", o["cwd"]) + "/" + o["id"] + ".jsonl")
    if os.path.exists(t): print(o["id"])
