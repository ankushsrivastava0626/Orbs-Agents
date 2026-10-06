#!/usr/bin/env python3
"""Voice session helpers for the pet.
  voice_sessions.py list              -> JSON: {"current": id, "sessions": [{id, cwd, name, started}]}  (newest first)
  voice_sessions.py transcript [id]   -> writes a readable Markdown transcript and prints its path
"""
import json, os, re, sys, time
V = os.path.expanduser("~/.claude/voice")
PROJECTS = os.path.expanduser("~/.claude/projects")

def jsonl(sid, cwd):
    p = os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", cwd), sid + ".jsonl")
    if os.path.exists(p): return p
    for d in os.listdir(PROJECTS):                      # fall back: search every project folder
        q = os.path.join(PROJECTS, d, sid + ".jsonl")
        if os.path.exists(q): return q
    return None

def user_text(e):
    c = e.get("message", {}).get("content")
    if isinstance(c, str): return c
    for b in c or []:
        if isinstance(b, dict) and b.get("type") == "text": return b.get("text", "")
    return ""

def name_of(sid, cwd):
    p = jsonl(sid, cwd)
    if p:
        for line in open(p):
            try: e = json.loads(line)
            except Exception: continue
            if e.get("type") == "user" and not e.get("isMeta"):
                t = user_text(e).strip()
                if t and not t.startswith("<"): return t[:60]
    return os.path.basename(cwd.rstrip("/")) + " · new"

def load():
    try: cur = json.load(open(os.path.join(V, "session.json"))).get("id")
    except Exception: cur = None
    try: lst = json.load(open(os.path.join(V, "sessions.json")))
    except Exception: lst = []
    out = [dict(s, name=name_of(s["id"], s["cwd"])) for s in reversed(lst)]
    return {"current": cur, "sessions": out}

def transcript(sid=None):
    data = load()
    sid = sid or data["current"]
    s = next((x for x in data["sessions"] if x["id"] == sid), None)
    if not s: sys.exit("no such session")
    p = jsonl(sid, s["cwd"])
    os.makedirs(os.path.join(V, "transcripts"), exist_ok=True)
    out = os.path.join(V, "transcripts", sid + ".md")
    lines = [f"# Voice session: {s['name']}", f"*{s['cwd']} · started {time.strftime('%Y-%m-%d %H:%M', time.localtime(s['started']))}*", ""]
    if p:
        for line in open(p):
            try: e = json.loads(line)
            except Exception: continue
            t = e.get("type")
            if t == "user" and not e.get("isMeta"):
                txt = user_text(e).strip()
                if txt and not txt.startswith("<"): lines += [f"**🎙 You:** {txt}", ""]
            elif t == "assistant":
                for b in e.get("message", {}).get("content", []):
                    if not isinstance(b, dict): continue
                    if b.get("type") == "tool_use" and b.get("name", "").endswith("speak"):
                        lines += [f"**🔊 Joe:** {b.get('input', {}).get('text', '')}", ""]
                    elif b.get("type") == "tool_use":
                        d = b.get("input", {}).get("description") or b.get("input", {}).get("url") or ""
                        lines += [f"> ⚙️ {b.get('name', '').split('__')[-1]}{': ' + d if d else ''}", ""]
                    elif b.get("type") == "text" and b.get("text", "").strip():
                        lines += [f"*{b['text'].strip()}*", ""]
    else:
        lines.append("_No transcript yet: say something first._")
    open(out, "w").write("\n".join(lines))
    print(out)

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "transcript": transcript(sys.argv[2] if len(sys.argv) > 2 else None)
    else: print(json.dumps(load()))
