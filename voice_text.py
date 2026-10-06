"""Pick the text Claude should speak, for Stop and PreToolUse hooks.

usage: voice_text.py pretool|stop MAX_SENTENCES   (hook JSON on stdin)
pretool: speaks assistant text written since the user's last message that hasn't been spoken yet.
stop:    speaks the final reply, unless it was already spoken mid-turn.
Spoken text is remembered per session (by hash) so nothing is said twice.
"""
import hashlib, json, os, re, sys

mode = sys.argv[1]
max_sentences = int(sys.argv[2]) if len(sys.argv) > 2 else 2
try: d = json.load(sys.stdin)
except Exception: sys.exit()

state_dir = "/tmp/claude-voice-spoken"
os.makedirs(state_dir, exist_ok=True)
state = os.path.join(state_dir, re.sub(r"[^\w-]", "", d.get("session_id", "default")))
spoken = set(open(state).read().split()) if os.path.exists(state) else set()

def clean(t):
    if max_sentences == 0:   # full reply for Joe: keep structure, drop only code
        return re.sub(r"```.*?```", "[code block omitted]", t, flags=re.S).strip()
    t = re.sub(r"```.*?```", " ", t, flags=re.S)
    t = re.sub(r"\[([^\]]+)\]\([^)]+\)", r"\1", t)        # links -> label
    t = re.sub(r"^\s*\|.*\|\s*$", "", t, flags=re.M)       # tables
    t = re.sub(r"^\s*[-•]\s+", "", t, flags=re.M)          # bullets
    t = re.sub(r"[`*_#>]", "", t)
    t = re.sub(r"\s+", " ", t).strip()
    return " ".join(re.split(r"(?<=[.!?])\s+", t)[:max_sentences])

def is_real_user(e):
    if e.get("type") != "user" or e.get("isMeta"): return False
    c = e.get("message", {}).get("content")
    if isinstance(c, str): return True
    return any(isinstance(b, dict) and b.get("type") == "text" for b in c or [])

turn = ""   # uuid of the user's latest message; spoken-keys are scoped to it

def texts_since_user():
    global turn
    out = []
    try:
        for line in open(d["transcript_path"]):
            e = json.loads(line)
            if is_real_user(e):
                out, turn = [], e.get("uuid", "")
            elif e.get("type") == "assistant":
                for b in e.get("message", {}).get("content", []):
                    if isinstance(b, dict) and b.get("type") == "text" and b.get("text", "").strip():
                        out.append(b["text"])
    except Exception:
        pass
    return out

texts = texts_since_user()
h = lambda t: hashlib.sha1((turn + t.strip()).encode()).hexdigest()[:16]   # same words in a new turn get spoken again
if mode == "pretool":
    new = [t for t in texts if h(t) not in spoken]
else:
    last = d.get("last_assistant_message") or (texts or [""])[-1]
    new = [last] if last.strip() and h(last) not in spoken else []

if new:
    with open(state, "a") as f:
        for t in new: f.write(h(t) + "\n")
    print(clean(new[-1]))   # newest thought only, so voice keeps up with the screen
