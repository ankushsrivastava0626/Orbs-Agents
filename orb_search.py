#!/usr/bin/env python3
"""Keyword search over every conversation an orb has had: Claude orb sessions in any config folder (~/.claude,
~/.claude-mercury, ~/.claude-openrouter, …) and the Codex orb conversations. Sessions started straight from
claude or codex (never an orb) are left out.
  orb_search.py [words…]   -> JSON list, best/newest first:
     [{kind, id, cwd, title, when, snippet, hits, command}]
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
    lines, first, title, cwd, orb, models = [], "", "", "", False, {}
    for raw in open(path, errors="ignore"):
        try: e = json.loads(raw)
        except Exception: continue
        t, msg = e.get("type"), e.get("message") or {}
        cwd = cwd or e.get("cwd") or ""
        if t == "agent-name" and re.fullmatch(r"voice(-\d+)?", e.get("agentName") or ""): orb = True   # the launcher's name
        if t == "custom-title": title = e.get("customTitle") or title          # the name it was given
        elif t == "user" and not e.get("isMeta"):
            for s in blocks(msg.get("content")):
                s = s.strip()
                if s and not s.startswith("<"):
                    lines.append("You: " + s)
                    if not first and not s.startswith("This session is being continued"):
                        first = next((l.strip() for l in s.splitlines() if l.strip()), "")   # its first line
        elif t == "assistant":
            md = msg.get("model") or ""
            if md and md != "<synthetic>": models[md] = models.get(md, 0) + 1
            for b in msg.get("content") or []:
                if not isinstance(b, dict): continue
                if b.get("type") == "text" and b.get("text", "").strip():
                    lines.append(b["text"].strip())
                elif b.get("type") == "tool_use" and b.get("name", "").endswith("speak"):
                    orb = orb or b.get("name") == "mcp__voice__speak"           # talked through an orb's voice
                    s = (b.get("input") or {}).get("text", "")
                    if s: lines.append(s)
    text = "\n".join(lines)
    if len(text) > 400_000: text = text[:200_000] + "\n…\n" + text[-200_000:]   # keeps the index small
    return first, text, title, cwd, orb, top_model(models)


def spoken(code):
    """What Codex said out loud: tools.speak({text:"…"}) inside its exec calls."""
    out = []
    for m in re.finditer(r'speak\(\s*\{\s*text\s*:\s*("(?:[^"\\]|\\.)*")', code):
        try: out.append(json.loads(m.group(1)))
        except Exception: pass
    return out


def top_model(counts):
    """The model it mostly ran on; OpenRouter writes some as "anthropic/z-ai/glm-…": keep the real name."""
    if not counts: return ""
    m = max(counts, key=counts.get)
    return m.split("/", 1)[1] if m.count("/") >= 2 else m


def codex_text(path):
    lines, first, models = [], "", {}
    for raw in open(path, errors="ignore"):
        try: e = json.loads(raw)
        except Exception: continue
        p = e.get("payload") or {}
        if e.get("type") == "turn_context" and p.get("model"): models[p["model"]] = models.get(p["model"], 0) + 1
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
    return first, "\n".join(lines), top_model(models)


def command_for(config_dir):
    """~/.claude-mercury → claude-mercury (resuming needs the same command that made it)."""
    base = os.path.basename(config_dir)
    if base == ".claude": return ""
    cmd = base.lstrip(".")
    return cmd if os.path.exists(os.path.expanduser("~/.local/bin/" + cmd)) else ""


def sessions():
    """Every Claude Code conversation in every config folder, plus the Codex orb conversations."""
    out, seen = [], set()
    for cfg in sorted(glob.glob(os.path.expanduser("~/.claude*"))):
        if not os.path.isdir(os.path.join(cfg, "projects")): continue
        cmd = command_for(cfg)
        for f in glob.glob(os.path.join(cfg, "projects", "*", "*.jsonl")):     # top level only: not subagents
            sid = os.path.basename(f)[:-6]
            if sid in seen: continue
            seen.add(sid)
            out.append({"kind": "claude", "id": sid, "cwd": "", "file": f, "name": "", "command": cmd})
    reg = load(os.path.join(CODEX_ROOT, "runtime", "sessions.json"), {}).get("sessions", [])
    for s in reg + [o for o in load(os.path.join(V, "orbs.json"), []) if o.get("kind") == "codex"]:
        sid = s.get("id")
        if not sid or sid in seen: continue
        seen.add(sid)
        f = codex_file(sid)
        if f: out.append({"kind": "codex", "id": sid, "cwd": s.get("cwd", ""), "file": f,
                          "name": s.get("name") or s.get("label") or "", "command": ""})
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
    launched = {x.get("id") for x in load(os.path.join(V, "sessions.json"), []) + load(os.path.join(V, "orbs.json"), [])}
    for s in sessions():
        f = s["file"]
        m = os.path.getmtime(f)
        c = cache.get(f)
        if not c or c.get("m") != m or c.get("v") != 3:
            if s["kind"] == "claude": first, text, ctitle, cwd, orb, model = claude_text(f)
            else: (first, text, model), ctitle, cwd, orb = codex_text(f), "", s["cwd"], True
            c = {"m": m, "first": first, "text": text, "title": ctitle, "cwd": cwd, "orb": orb, "model": model, "v": 3}
        fresh[f] = c
        if not (c["orb"] or s["id"] in launched): continue           # never an orb's: started straight from claude
        if not c["text"].strip(): continue                    # never actually talked to it
        cwd = c.get("cwd") or s["cwd"]
        named = c.get("title") if not re.fullmatch(r"voice(-\d+)?", c.get("title") or "") else ""   # "voice-3" is just the orb
        title = names.get(s["id"]) or named or c["first"][:80] or s["name"] or os.path.basename(cwd.rstrip("/"))
        # what's searched: the title, the folder path, and everything said — titles and folders count most
        head = (title + " " + (c.get("title") or "") + " " + (names.get(s["id"]) or "")).lower()
        folder = cwd.lower()
        body = c["text"].lower()
        pats = [re.compile(r"(?<![a-z0-9])" + re.escape(w)) for w in words]   # words start at a word boundary
        def has(p, t): return p.search(t) is not None
        if words and not all(has(p, head) or has(p, folder) or has(p, body) for p in pats): continue
        phrase = re.compile(r"(?<![a-z0-9])" + r"[\s_-]*".join(map(re.escape, words))) if len(words) > 1 else None
        score = 0
        for p in pats:
            score += 60 * has(p, head) + 40 * has(p, folder) + 10 * has(p, c["first"].lower()) + min(len(p.findall(body)), 20)
        if phrase and (has(phrase, head) or has(phrase, folder)): score += 150      # the exact phrase in title/folder
        elif phrase and has(phrase, body): score += 30
        results.append({"kind": s["kind"], "id": s["id"], "cwd": cwd, "title": title, "name": s["name"], "when": m,
                        "snippet": snippet(c["text"], words), "hits": score,
                        "command": s["command"], "model": c.get("model") or ("codex" if s["kind"] == "codex" else "claude")})
    os.makedirs(os.path.dirname(CACHE), exist_ok=True)
    try:
        json.dump(fresh, open(CACHE + ".tmp", "w")); os.replace(CACHE + ".tmp", CACHE)
    except Exception: pass
    results.sort(key=lambda r: (-r["hits"] if words else 0, -r["when"]))
    print(json.dumps(results[:200]))


if __name__ == "__main__":
    main()
