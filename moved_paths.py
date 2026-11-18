"""Folders that moved. A conversation remembers the folder it ran in; when that folder has since moved, this maps
the old path to its new home and links the conversation into the new folder's list so `claude --resume` finds it.
List your moves in ~/.claude/voice/moved.json (old prefix -> new prefix, longest match wins):
    {"~/old/projects": "~/new/projects"}"""
import json, os, re, sys

H = os.path.expanduser("~")

def _moves():
    p = os.path.join(H, ".claude", "voice", "moved.json")
    if not os.path.exists(p): return {}
    try: raw = json.load(open(p))
    except ValueError as e:
        print("moved.json is not valid JSON:", e, file=sys.stderr); return {}
    return {os.path.expanduser(k).rstrip("/"): os.path.expanduser(v).rstrip("/") for k, v in raw.items()}

MOVED = _moves()                                  # old prefix -> new prefix

def where(cwd):
    """The folder now: itself if it still exists, else its new home (or "" if unknown)."""
    if not cwd or os.path.isdir(cwd): return cwd
    for old in sorted(MOVED, key=len, reverse=True):
        if cwd == old or cwd.startswith(old + "/"):
            new = MOVED[old] + cwd[len(old):]
            if os.path.isdir(new): return new
    return ""

def link_transcript(transcript, new_cwd):
    """Make the conversation resumable from its new folder (a link, so both names see the same file)."""
    cfg = transcript.split("/projects/")[0]
    d = os.path.join(cfg, "projects", re.sub(r"[^A-Za-z0-9]", "-", new_cwd))
    dst = os.path.join(d, os.path.basename(transcript))
    if os.path.realpath(dst) == os.path.realpath(transcript): return
    os.makedirs(d, exist_ok=True)
    if not os.path.lexists(dst): os.symlink(transcript, dst)

if __name__ == "__main__":
    print(where(sys.argv[1]))
