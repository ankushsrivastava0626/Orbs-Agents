"""Folders that moved (Nov 2026: everything went into ~/1/…). Conversations remember the folder they ran in;
this maps an old folder to where it lives now, and links the conversation into the new folder's list so
`claude --resume` finds it there. Add a line to MOVED when you move something else."""
import os, re, sys

H = os.path.expanduser("~")
MOVED = {                                         # old prefix -> new prefix (longest match wins)
    H + "/Githubs": H + "/1/02_Projects/Repos",
    H + "/OR": H + "/1/05_Personal/Finance/OR",
    H + "/claude-runpod": H + "/1/02_Projects/Active/claude-runpod",
}

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
