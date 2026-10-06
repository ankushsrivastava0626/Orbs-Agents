#!/bin/bash
# (Re)start the Claude voice session in tmux: Joe persona, speak tool, Chrome.
#   start-voice-session.sh                    new session in the last folder (default: persistent agent)
#   start-voice-session.sh --cwd /some/dir    new session in that folder
#   start-voice-session.sh --resume <id>      resume a previous voice session (in its own folder)
#   ... --name voice-2                         run it as another orb/session (tmux session name; default "voice")
#   ... --fresh                                always a brand-new conversation
# With no --resume and no --fresh, an orb resumes its own last conversation (after a restart or a crash).
# Full paths: this also runs from the voice server's / pet's minimal launchd environment.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
V="$HOME/.claude/voice"; TMUX_BIN=/opt/homebrew/bin/tmux
CWD="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cwd",""))' "$V/session.json" 2>/dev/null)"
[ -d "$CWD" ] || CWD="/Users/kush/Githubs/persistent agent"
RESUME=""; NAME="voice"; FRESH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --cwd) CWD="$2"; shift 2 ;;
    --resume) RESUME="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# no explicit choice: pick the orb's own conversation back up, if its transcript exists
if [ -z "$RESUME" ] && [ "$FRESH" = 0 ]; then
  RESUME="$(/usr/bin/python3 "$V/orb_last_session.py" "$V/orbs.json" "$NAME")"
fi
if [ -n "$RESUME" ]; then
  ID="$RESUME"
  C=$(/usr/bin/python3 -c 'import json,sys
for s in json.load(open(sys.argv[1])):
    if s["id"]==sys.argv[2]: print(s["cwd"])' "$V/sessions.json" "$ID" 2>/dev/null | head -1)
  [ -d "$C" ] && CWD="$C"
  SESS="--resume $ID"
else
  ID=$(/usr/bin/uuidgen | tr 'A-Z' 'a-z')
  SESS="--session-id $ID"
fi
# remember the current session, and keep a list of voice sessions for "Resume"
/usr/bin/python3 - "$V" "$ID" "$CWD" "$NAME" <<'PY'
import json, os, sys, time
v, sid, cwd, name = sys.argv[1:5]
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
orbs = [o for o in orbs if o.get("name") != name] + [entry]
orbs.sort(key=lambda o: o["name"] != "voice")              # default orb first; others keep their order
json.dump(orbs, open(op, "w"), indent=1)
p = os.path.join(v, "sessions.json")
try: lst = json.load(open(p))
except Exception: lst = []
lst = [s for s in lst if s["id"] != sid] + [{"id": sid, "cwd": cwd, "started": time.time()}]
json.dump(lst[-50:], open(p, "w"), indent=1)
PY
$TMUX_BIN kill-session -t "$NAME" 2>/dev/null
$TMUX_BIN new-session -d -s "$NAME" -x 200 -y 50 -c "$CWD" \
  "export PATH='$PATH'; VOICE_SESSION=1 VOICE_SESSION_NAME=$NAME $HOME/.local/bin/claude --chrome --name $NAME $SESS --mcp-config $V/voice-mcp.json --append-system-prompt \"\$(cat $V/voice-system-prompt.md)\""
