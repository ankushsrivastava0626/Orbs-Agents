import glob, json, os, re, sys
try: orbs = json.load(open(sys.argv[1]))
except Exception: orbs = []
o = next((o for o in orbs if o.get("name") == sys.argv[2] and o.get("kind") == "claude"), None)
if o and o.get("id"):
    # any Claude config folder: ~/.claude, or a wrapper's own (e.g. ~/.claude-openrouter)
    if glob.glob(os.path.expanduser("~/.claude*/projects/*/" + o["id"] + ".jsonl")): print(o["id"])
