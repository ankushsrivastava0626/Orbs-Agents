#!/bin/bash
# (Re)start the Claude voice session in tmux: Joe persona, speak tool, Chrome.
#   start-voice-session.sh                    new session in the last folder (default: DEFAULT_CWD in config, else ~)
#   start-voice-session.sh --cwd /some/dir    new session in that folder
#   start-voice-session.sh --resume <id>      resume a previous voice session (in its own folder)
#   ... --name voice-2                         run it as another orb/session (tmux session name; default "voice")
#   ... --fresh                                always a brand-new conversation
#   ... --cmd "claude-openrouter"              run this command instead of claude (kept with the orb)
#   ... --agent <slug>                         run an agent designed in CUE Studio (agents/<slug>/; kept with the orb)
# With no --resume and no --fresh, an orb resumes its own last conversation (after a restart or a crash).
# Full paths: this also runs from the voice server's / pet's minimal launchd environment.
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
V="$HOME/.claude/voice"; TMUX_BIN=/opt/homebrew/bin/tmux
CWD="$(/usr/bin/python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("cwd",""))' "$V/session.json" 2>/dev/null)"
[ -d "$CWD" ] || CWD="$(/usr/bin/python3 -c 'import os,sys
v=[l.split("#",1)[0].split("=",1)[1].strip().strip(chr(34)) for l in open(sys.argv[1]) if "=" in l and l.split("=",1)[0].strip()=="DEFAULT_CWD"]
print(os.path.expanduser(v[-1]) if v else "")' "$V/config" 2>/dev/null)"
[ -d "$CWD" ] || CWD="$HOME"
RESUME=""; NAME="voice"; FRESH=0; CMD=""; MODEL_ARG=""; AGENT=""; AGENT_ARGS=""; PROMPT="$V/voice-system-prompt.md"
while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --fresh) FRESH=1; shift ;;
    --cwd) CWD="$2"; shift 2 ;;
    --resume) RESUME="$2"; shift 2 ;;
    --cmd) CMD="$2"; shift 2 ;;
    --agent) AGENT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
# an orb started with a custom command keeps using it (relaunch, resume)
[ -z "$CMD" ] && CMD="$(/usr/bin/python3 -c 'import json,sys
o=next((o for o in json.load(open(sys.argv[1])) if o.get("name")==sys.argv[2]),{});print(o.get("command",""))' "$V/orbs.json" "$NAME" 2>/dev/null)"
# an orb made from a CUE Studio agent keeps being that agent (relaunch, resume)
[ -z "$AGENT" ] && AGENT="$(/usr/bin/python3 -c 'import json,sys
o=next((o for o in json.load(open(sys.argv[1])) if o.get("name")==sys.argv[2]),{});print(o.get("agent",""))' "$V/orbs.json" "$NAME" 2>/dev/null)"
if [ -n "$AGENT" ]; then
  mkdir -p "$V/run"; PROMPT="$V/run/$NAME.prompt.md"
  AJ="$(/usr/bin/python3 "$V/orb_agent.py" "$AGENT" "$PROMPT")" || { echo "agent $AGENT: can't read agents/$AGENT/"; exit 1; }
  CMD="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["cmd"])' "$AJ")"
  AGENT_ARGS="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["args"])' "$AJ")"
  AM="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["model"])' "$AJ")"
  AC="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["cwd"])' "$AJ")"
  [ -d "$AC" ] && CWD="$AC"
  # always the custom-command line below (it passes the voice hooks); orb_agent.py already adds them
fi
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
cwd, model = "", ""
for raw in open(f, errors="ignore"):
    if not cwd and '"cwd"' in raw:
        try: cwd = json.loads(raw).get("cwd") or ""
        except Exception: pass
    if '"type":"assistant"' in raw:          # the model of its last real reply (not "<synthetic>" notices)
        try: m = (json.loads(raw).get("message") or {}).get("model") or ""
        except Exception: continue
        if m and m != "<synthetic>": model = m
if cwd and not os.path.isdir(cwd):                # its folder moved: run it from the new one
    sys.path.insert(0, os.path.expanduser("~/.claude/voice"))
    import moved_paths
    new = moved_paths.where(cwd)
    if new:
        f = os.path.realpath(f); moved_paths.link_transcript(f, new); cwd = new
print(json.dumps({"cmd": cmd, "cwd": cwd, "model": model}))
PY
)"
  if [ -n "$FIX" ]; then
    CMD="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["cmd"])' "$FIX")"
    FC="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["cwd"])' "$FIX")"
    [ -d "$FC" ] && CWD="$FC"
    # back on the model it was actually using (a wrapper's own default, e.g. ANTHROPIC_MODEL, would win otherwise)
    MODEL="$(/usr/bin/python3 -c 'import json,sys;print(json.loads(sys.argv[1])["model"])' "$FIX")"
    if [ -n "$MODEL" ]; then
      CMD="$(/usr/bin/python3 -c 'import re,sys;print(re.sub(r"\s--model(=|\s+)\S+", "", " " + sys.argv[1]).strip())' "$CMD")"
      MODEL_ARG="--model '$MODEL'"
    fi
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
# your own system prompt for this conversation (orb menu → System prompt…): added after the voice instructions
if [ -s "$V/prompts/$ID.md" ]; then
  mkdir -p "$V/run"; P2="$V/run/$NAME.full-prompt.md"
  { cat "$PROMPT"; printf '\n\n# YOUR INSTRUCTIONS FOR THIS SESSION\n\n'; cat "$V/prompts/$ID.md"; } > "$P2"
  PROMPT="$P2"
fi
# remember the current session, and keep a list of voice sessions for "Resume"
/usr/bin/python3 - "$V" "$ID" "$CWD" "$NAME" "$CMD" "$AGENT" <<'PY'
import fcntl, json, os, sys, time
v, sid, cwd, name, cmd, agent = sys.argv[1:7]
# two orbs starting at once must not write over each other: one at a time, and each file swapped in whole
lock = open(os.path.join(v, ".launch.lock"), "w"); fcntl.flock(lock, fcntl.LOCK_EX)
def save(path, data):
    json.dump(data, open(path + ".tmp", "w"), indent=1); os.replace(path + ".tmp", path)
if name == "voice":
    save(os.path.join(v, "session.json"), {"id": sid, "cwd": cwd, "started": time.time()})
# orbs.json: one entry per orb/session, read by the pet
op = os.path.join(v, "orbs.json")
try: orbs = json.load(open(op))
except Exception: orbs = []
old = next((o for o in orbs if o.get("name") == name), {})
entry = {"name": name, "kind": "claude", "id": sid, "cwd": cwd}
if "hotkey" in old: entry["hotkey"] = old["hotkey"]          # keep the orb's speak hotkey
if "label" in old: entry["label"] = old["label"]
if agent:
    entry["agent"] = agent
    try: entry["label"] = json.load(open(os.path.join(v, "agents", agent, "agent.json"))).get("name") or agent
    except Exception: entry["label"] = agent
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
[ -n "$AGENT" ] && [ -n "$AM" ] && MODEL_ARG="--model '$AM'"   # the design's model, also on resume
$TMUX_BIN kill-session -t "=$NAME" 2>/dev/null          # exact name: "voice" must not hit "voice-2"
if [ -z "$CMD" ]; then
  $TMUX_BIN new-session -d -s "$NAME" -x 200 -y 50 -c "$CWD" \
    "export PATH='$PATH'; VOICE_SESSION=1 VOICE_SESSION_NAME=$NAME $HOME/.local/bin/claude --chrome --name $NAME $SESS $MODEL_ARG --mcp-config $V/voice-mcp.json $AGENT_ARGS --append-system-prompt \"\$(cat '$PROMPT')\""
else
  # your command, through your interactive zsh (so aliases work), with the voice options added
  mkdir -p "$V/run"; R="$V/run/$NAME.zsh"
  {
    echo "export PATH='$PATH' VOICE_SESSION=1 VOICE_SESSION_NAME=$NAME VOICE_HOOKS_FLAG=1"
    HOOKS="--settings $V/voice-hooks.json"; [ -n "$AGENT" ] && HOOKS=""
    echo "$CMD --name $NAME $SESS $MODEL_ARG --mcp-config $V/voice-mcp.json $AGENT_ARGS $HOOKS --append-system-prompt \"\$(cat '$PROMPT')\""
  } > "$R"
  $TMUX_BIN new-session -d -s "$NAME" -x 200 -y 50 -c "$CWD" "/bin/zsh -i $R"
fi
