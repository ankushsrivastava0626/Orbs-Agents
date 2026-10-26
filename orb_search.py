#!/usr/bin/env python3
"""Keyword search over every conversation an orb has ever had (Claude and Codex).
  orb_search.py [words…]   -> JSON list, best/newest first:
     [{kind, id, cwd, title, when, snippet, hits}]
Every word must appear (case-insensitive). No words: every session, newest first.
Text pulled from each transcript is cached by file mtime, so hundreds of sessions stay fast."""
import glob, json, os, re, sys

V = os.path.expanduser("~/.claude/voice")
PROJECTS = os.path.expanduser("~/.claude/projects")
CODEX_ROOT = "/Users/kush/Documents/Codex/2026-10-04/can-x20/outputs/codex-voice-assistant"
CACHE = os.path.join(V, "cache", "search_index.json")


def load(p, default):
    try: return json.load(open(p))
    except Exception: return default


def claude_file(sid, cwd):
    p = os.path.join(PROJECTS, re.sub(r"[^A-Za-z0-9]", "-", cwd or ""), sid + ".jsonl")
    if os.path.exists(p): return p
    hits = glob.glob(os.path.expanduser("~/.claude*/projects/*/" + sid + ".jsonl"))   # wrappers keep their own folder
    return hits[0] if hits else None


def codex_file(sid):
    hits = glob.glob(os.path.expanduser(f"~/.codex/sessions/**/rollout-*{sid}.jsonl"), recursive=True)
    return max(hits, key=os.path.getmtime) if hits else None


def blocks(c):
    if isinstance(c, str): return [c]
    return [b.get("text", "") for b in c or [] if isinstance(b, dict) and b.get("type") in ("text", "input_text", "output_text")]


def claude_text(path):
    lines, first = [], ""
    for raw in open(path, errors="ignore"):
        try: e = json.loads(raw)
        except Exception: continue
        t, msg = e.get("type"), e.get("message") or {}
        if t == "user" and not e.get("isMeta"):
            for s in blocks(msg.get("content")):
                s = s.strip()
                if s and not s.startswith("<"):
                    lines.append("You: " + s); first = first or s
        elif t == "assistant":
            for b in msg.get("content") or []:
                if not isinstance(b, dict): continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    lines.append(b["text"].strip())
                elif b.get("type") == "tool_use" and b.get("name", "").endswith("speak"):
                    s = (b.get("input") or {}).get("text", "")
                    if s: lines.append(s)
    return first, "\n".join(lines)


def spoken(code):
    """What Codex said out loud: tools.speak({text:"…"}) inside its exec calls."""
    out = []
    for m in re.finditer(r'speak\(\s*\{\s*text\s*:\s*("(?:[^"\\]|\\.)*")', code):
        try: out.append(json.loads(m.group(1)))
        except Exception: pass
    return out


def codex_text(path):
    lines, first = [], ""
    for raw in open(path, errors="ignore"):
        try: e = json.loads(raw)
        except Exception: continue
        p = e.get("payload") or {}
        if e.get("type") == "response_item" and p.get("type") == "custom_tool_call":
            lines += spoken(p.get("input") or "")
            continue
        if e.get("type") != "response_item" or p.get("type") != "message" or p.get("role") not in ("user", "assistant"):
            continue
        for s in blocks(p.get("content")):
            s = s.strip()
            if not s or s.startswith("<"): continue
            if p["role"] == "user":
                lines.append("You: " + s); first = first or s
            else:
                lines.append(s)
    return first, "\n".join(lines)


def sessions():
    """Every orb session we know of: Claude launches (sessions.json, orbs.json) and the Codex registry."""
    out, seen = [], set()
    claude = load(os.path.join(V, "sessions.json"), []) + [o for o in load(os.path.join(V, "orbs.json"), []) if o.get("kind") == "claude"]
    for s in claude:
        sid = s.get("id")
        if not sid or sid in seen: continue
        seen.add(sid)
        f = claude_file(sid, s.get("cwd"))
        if f: out.append({"kind": "claude", "id": sid, "cwd": s.get("cwd", ""), "file": f, "name": ""})
    reg = load(os.path.join(CODEX_ROOT, "runtime", "sessions.json"), {}).get("sessions", [])
    for s in reg + [o for o in load(os.path.join(V, "orbs.json"), []) if o.get("kind") == "codex"]:
        sid = s.get("id")
        if not sid or sid in seen: continue
        seen.add(sid)
        f = codex_file(sid)
        if f: out.append({"kind": "codex", "id": sid, "cwd": s.get("cwd", ""), "file": f, "name": s.get("name") or s.get("label") or ""})
    return out


def snippet(text, words):
    low = text.lower()
    i = min((low.find(w) for w in words if low.find(w) >= 0), default=-1)
    if i < 0:
        s = text.strip().split("\n")[-1] if text.strip() else ""
        return s[:160]
    a = max(0, i - 60)
    s = text[a:i + 120].replace("\n", " · ")
    return ("…" if a else "") + s.strip() + "…"


def main():
    words = [w.lower() for w in sys.argv[1:] for w in w.split() if w.strip()]
    cache = load(CACHE, {})
    names = load(os.path.join(V, "orb_names.json"), {})
    fresh = {}
    results = []
    for s in sessions():
        f = s["file"]
        m = os.path.getmtime(f)
        c = cache.get(f)
        if not c or c.get("m") != m:
            first, text = (claude_text if s["kind"] == "claude" else codex_text)(f)
            c = {"m": m, "first": first, "text": text}
        fresh[f] = c
        if not c["text"].strip(): continue                    # never actually talked to it
        low = c["text"].lower()
        if names.get(s["id"]): low = names[s["id"]].lower() + "\n" + low      # its name is searchable too
        if words and not all(w in low for w in words): continue
        title = names.get(s["id"]) or c["first"][:80] or s["name"] or os.path.basename(s["cwd"].rstrip("/"))
        results.append({"kind": s["kind"], "id": s["id"], "cwd": s["cwd"], "title": title, "name": s["name"], "when": m,
                        "snippet": snippet(c["text"], words), "hits": sum(low.count(w) for w in words)})
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    try:
        json.dump(fresh, open(CACHE + ".tmp", "w")); os.replace(CACHE + ".tmp", CACHE)
    except Exception: pass
    results.sort(key=lambda r: (-r["hits"] if words else 0, -r["when"]))
    print(json.dumps(results[:200]))


if __name__ == "__main__":
    main()
