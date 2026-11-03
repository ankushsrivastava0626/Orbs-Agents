#!/bin/bash
# (Re)start the Claude voice session in tmux: Joe persona, speak tool, Chrome.
#   start-voice-session.sh                    new session in the last folder (default: persistent agent)
#   start-voice-session.sh --cwd /some/dir    new session in that folder
#   start-voice-session.sh --resume <id>      resume a previous voice session (in its own folder)
#   ... --name voice-2                         run it as another orb/session (tmux session name; default "voice")
#   ... --fresh                                always a brand-new conversation
#   ... --cmd "claude-openrouter"              run this command instead of claude (kept with the orb)
# With no --resume and no --fresh, an orb resumes its own last conversation (after a restart or a crash).
# Full paths: this also runs from the voice server's / pet's minimal launchd environment.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
V="$HOME/.claude/voice"; TMUX_BIN=/opt/homebrew/bin/tmux
CWD="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cwd",""))' "$V/session.json" 2>/dev/null)"
[ -d "$CWD" ] || CWD="/Users/kush/Githubs/persistent agent"
RESUME=""; NAME="voice"; FRESH=0; CMD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --cwd) CWD="$2"; shift 2 ;;
    --resume) RESUME="$2"; shift 2 ;;
    --cmd) CMD="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# an orb started with a custom command keeps using it (relaunch, resume)
[ -z "$CMD" ] && CMD="$(/usr/bin/python3 -c 'import json,sys
o=next((o for o in json.load(open(sys.argv[1])) if o.get("name")==sys.argv[2]),{});print(o.get("command",""))' "$V/orbs.json" "$NAME" 2>/dev/null)"
# no explicit choice: pick the orb's own conversation back up, if its transcript exists
if [ -z "$RESUME" ] && [ "$FRESH" = 0 ]; then
  RESUME="$(/usr/bin/python3 "$V/orb_last_session.py" "$V/orbs.json" "$NAME")"
fi
if [ -n "$RESUME" ]; then
  ID="$RESUME"
  # Resume exactly this conversation: its transcript says which command (config folder) and which folder it
  # belongs to. Claude treats an ID it can't find as a search term and opens a different one, so never guess.
  FIX="$(/usr/bin/python3 - "$ID" "$CMD" <<'PY'
import glob, json, os, sys
sid, cmd = sys.argv[1:3]
f = next(iter(glob.glob(os.path.expanduser("~/.claude*/projects/*/" + sid + ".jsonl"))), "")
if not f: sys.exit()
cfg = os.path.basename(f.split("/projects/")[0])                  # .claude / .claude-openrouter / …
want = "" if cfg == ".claude" else cfg.lstrip(".")
have = os.path.basename(cmd.split()[0]) if cmd.strip() else ""
if have in ("", "claude"): have = ""
if want != have: cmd = want                                      # the orb's old command can't open it
cwd = ""
for raw in open(f, errors="ignore"):
    if '"cwd"' in raw:
        try: cwd = json.loads(raw).get("cwd") or ""
        except Exception: continue
        if cwd: break
print(json.dumps({"cmd": cmd, "cwd": cwd}))
PY
)"
  if [ -n "$FIX" ]; then
    CMD="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["cmd"])' "$FIX")"
    FC="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["cwd"])' "$FIX")"
    [ -d "$FC" ] && CWD="$FC"
  fi
  if [ -z "$FIX" ]; then                        # no transcript found: fall back to what the launch list says
    C=$(/usr/bin/python3 -c 'import json,sys
for s in json.load(open(sys.argv[1])):
    if s["id"]==sys.argv[2]: print(s["cwd"])' "$V/sessions.json" "$ID" 2>/dev/null | head -1)
    [ -d "$C" ] && CWD="$C"
  fi
  SESS="--resume $ID"
else
  ID=$(/usr/bin/uuidgen | tr 'A-Z' 'a-z')
  SESS="--session-id $ID"
fi
# remember the current session, and keep a list of voice sessions for "Resume"
/usr/bin/python3 - "$V" "$ID" "$CWD" "$NAME" "$CMD" <<'PY'
import fcntl, json, os, sys, time
v, sid, cwd, name, cmd = sys.argv[1:6]
# two orbs starting at once must not write over each other: one at a time, and each file swapped in whole
lock = open(os.path.join(v, ".launch.lock"), "w"); fcntl.flock(lock, fcntl.LOCK_EX)
def save(path, data):
    json.dump(data, open(path + ".tmp", "w"), indent=1); os.replace(path + ".tmp", path)
if name == "voice":
    json.dump({"id": sid, "cwd": cwd, "started": time.time()}, open(os.path.join(v, "session.json"), "w"))
# orbs.json: one entry per orb/session, read by the pet
op = os.path.join(v, "orbs.json")
try: orbs = json.load(open(op))
except Exception: orbs = []
old = next((o for o in orbs if o.get("name") == name), {})
entry = {"name": name, "kind": "claude", "id": sid, "cwd": cwd}
if "hotkey" in old: entry["hotkey"] = old["hotkey"]          # keep the orb's speak hotkey
if "label" in old: entry["label"] = old["label"]
if cmd:
    entry["command"] = cmd
    entry.setdefault("label", cmd.split()[0].split("/")[-1] + " · " + os.path.basename(cwd.rstrip("/")))
i = next((k for k, o in enumerate(orbs) if o.get("name") == name), None)
if i is None: orbs.append(entry)                            # new orb goes at the end
else: orbs[i] = entry                                       # relaunch/resume: keep its place in the dock
save(op, orbs)
p = os.path.join(v, "sessions.json")
try: lst = json.load(open(p))
except Exception: lst = []
lst = [s for s in lst if s["id"] != sid] + [{"id": sid, "cwd": cwd, "started": time.time()}]
save(p, lst[-500:])
PY
$TMUX_BIN kill-session -t "$NAME" 2>/dev/null
if [ -z "$CMD" ]; then
  $TMUX_BIN new-session -d -s "$NAME" -x 200 -y 50 -c "$CWD" \
    "export PATH='$PATH'; VOICE_SESSION=1 VOICE_SESSION_NAME=$NAME $HOME/.local/bin/claude --chrome --name $NAME $SESS --mcp-config $V/voice-mcp.json --append-system-prompt \"\$(cat $V/voice-system-prompt.md)\""
else
  # your command, through your interactive zsh (so aliases work), with the voice options added
  mkdir -p "$V/run"; R="$V/run/$NAME.zsh"
  {
    echo "export PATH='$PATH' VOICE_SESSION=1 VOICE_SESSION_NAME=$NAME VOICE_HOOKS_FLAG=1"
    echo "$CMD --name $NAME $SESS --mcp-config $V/voice-mcp.json --settings $V/voice-hooks.json --append-system-prompt \"\$(cat $V/voice-system-prompt.md)\""
  } > "$R"
  $TMUX_BIN new-session -d -s "$NAME" -x 200 -y 50 -c "$CWD" "/bin/zsh -i $R"
fi
