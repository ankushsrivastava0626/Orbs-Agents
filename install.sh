#!/bin/bash
# Orbs Agents installer — macOS 15 or later on Apple silicon. Run it from the clone at ~/.claude/voice:
#   ./install.sh              set everything up (safe to run again: what's already done is left alone)
#   ./install.sh --dry-run    show what it would do and change nothing
#   ./install.sh --no-login   don't install the two login agents (voice server and app)
#   ./install.sh --no-build   don't build the app
#   ./install.sh --uninstall  stop both and remove the login agents and Claude Code hooks (your data stays)
set -euo pipefail
V="$HOME/.claude/voice"
DRY=0; LOGIN=1; BUILD=1; UNINSTALL=0
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;; --no-login) LOGIN=0 ;; --no-build) BUILD=0 ;; --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "install.sh: unknown option $a (see --help)" >&2; exit 2 ;;
  esac
done
B=$'\033[1m'; D=$'\033[2m'; R=$'\033[0m'
say()  { printf '\n%s%s%s\n' "$B" "$*" "$R"; }
ok()   { printf '  ✓ %s\n' "$*"; }
die()  { printf '  ✗ %s\n' "$*" >&2; exit 1; }
NEXT=""; next() { NEXT="$NEXT$*"$'\n'; }
run()  { if [ $DRY = 1 ]; then printf '  %swould run:%s %s\n' "$D" "$R" "$*"; else "$@"; fi; }
GUI="gui/$(id -u)"
AGENTS="com.claude.kitten-tts com.claude.voice-pet"

# Claude Code hooks that tell the orbs what a session is doing (working, the current step, done).
hooks() {   # hooks add|remove|check
  /usr/bin/python3 - "$1" "$DRY" <<'PY'
import json, os, shutil, sys
mode, dry = sys.argv[1], sys.argv[2] == "1"
p = os.path.expanduser("~/.claude/settings.json")
s = json.load(open(p)) if os.path.exists(p) else {}
hooks = s.setdefault("hooks", {})
want = {"UserPromptSubmit": ("Prompt", None), "PreToolUse": ("Step", "*"), "Stop": ("Stop", None)}
ours = lambda h: "/.claude/voice/event.sh" in h.get("command", "")
changed = []
for event, (arg, matcher) in want.items():
    groups = hooks.setdefault(event, [])
    has = any(ours(h) for g in groups for h in g.get("hooks", []))
    if mode == "add" and not has:
        g = {"hooks": [{"type": "command", "command": f"~/.claude/voice/event.sh {arg}", "timeout": 3}]}
        groups.append({"matcher": matcher, **g} if matcher else g); changed.append(event)
    if mode == "remove" and has:
        for g in groups: g["hooks"] = [h for h in g.get("hooks", []) if not ours(h)]
        hooks[event] = [g for g in groups if g.get("hooks")]; changed.append(event)
    if not hooks[event]: del hooks[event]
if not changed:
    print("  ✓ Claude Code hooks " + ("already there" if mode == "add" else "not present")); sys.exit()
if dry:
    print(f"  would {mode} event.sh hooks ({', '.join(changed)}) in {p}"); sys.exit()
if os.path.exists(p): shutil.copy2(p, p + ".before-orbs")
os.makedirs(os.path.dirname(p), exist_ok=True)
json.dump(s, open(p + ".tmp", "w"), indent=2); os.replace(p + ".tmp", p)
print(f"  ✓ Claude Code hooks {'added' if mode == 'add' else 'removed'} ({', '.join(changed)}); backup: settings.json.before-orbs")
PY
}

if [ $UNINSTALL = 1 ]; then
  say "Removing Orbs Agents from login"
  for L in $AGENTS; do
    run launchctl bootout "$GUI/$L" 2>/dev/null || true
    run rm -f "$HOME/Library/LaunchAgents/$L.plist"
  done
  ok "voice server and app stopped; login agents removed"
  hooks remove
  printf '\n  Orb sessions keep running in tmux (see them with: tmux ls).\n'
  printf '  Your conversations, notes, meetings and task cards stay in %s; delete that folder to remove everything.\n' "$V"
  exit 0
fi

say "Checking your Mac"
[ "$(uname -s)" = Darwin ] || die "Orbs Agents runs on macOS only."
[ "$(uname -m)" = arm64 ] || die "Orbs Agents needs an Apple silicon Mac."
OS=$(sw_vers -productVersion); [ "${OS%%.*}" -ge 15 ] || die "Orbs Agents needs macOS 15 or later (this Mac has $OS)."
ok "macOS $OS on Apple silicon"
HERE="$(cd "$(dirname "$0")" && pwd -P)"
[ "$HERE" = "$(cd "$V" 2>/dev/null && pwd -P)" ] ||
  die "Clone Orbs Agents into ~/.claude/voice (the hooks and scripts live there):  git clone https://github.com/ankushsrivastava0626/Orbs-Agents ~/.claude/voice"
ok "installed at ~/.claude/voice"
xcode-select -p >/dev/null 2>&1 || die "Install Apple's Command Line Tools first:  xcode-select --install"
ok "Command Line Tools (swiftc)"
[ -x /opt/homebrew/bin/brew ] || die "Install Homebrew first: https://brew.sh"
MISSING=""
[ -x /opt/homebrew/bin/tmux ] && ok "tmux" || MISSING="$MISSING tmux"
PY=""
for p in /opt/homebrew/opt/python@3.12/bin/python3.12 "$(command -v python3.12 2>/dev/null || true)"; do
  [ -n "$p" ] && [ -x "$p" ] && { PY="$p"; break; }
done
[ -n "$PY" ] && ok "Python 3.12" || MISSING="$MISSING python@3.12"
command -v jq >/dev/null 2>&1 && ok "jq" || MISSING="$MISSING jq"
[ -z "$MISSING" ] || die "Missing:$MISSING. Install with:  brew install$MISSING"
if [ -x "$HOME/.local/bin/claude" ]; then ok "Claude Code"
else next "Install Claude Code, which every orb runs:  curl -fsSL https://claude.ai/install.sh | bash"; fi

say "Voice server"
if [ -x "$V/kitten-venv/bin/python" ]; then ok "Python environment (kitten-venv)"
else run "$PY" -m venv "$V/kitten-venv"; fi
run "$V/kitten-venv/bin/pip" install --quiet --disable-pip-version-check -r "$V/requirements.txt"
[ $DRY = 1 ] || ok "Python packages"
if [ -f "$V/config" ]; then ok "config (yours, left as it is)"
else run cp "$V/config.example" "$V/config"; [ $DRY = 1 ] || ok "config created from config.example"; fi
CFG="$V/config"; [ -f "$CFG" ] || CFG="$V/config.example"
ENVF=$(/usr/bin/python3 -c 'import os,sys
v=[l.split("#",1)[0].split("=",1)[1].strip().strip(chr(34)) for l in open(sys.argv[1]) if "=" in l and l.split("=",1)[0].strip()=="OPENROUTER_ENV"]
print(os.path.expanduser(v[-1]) if v else os.path.expanduser("~/.claude/voice/.env"))' "$CFG")
if [ -f "$ENVF" ] && grep -q '^OPENROUTER_API_KEY=.' "$ENVF"; then ok "OpenRouter key file ($ENVF)"
else
  [ -f "$ENVF" ] || run /bin/sh -c "umask 077; printf 'OPENROUTER_API_KEY=\n' > '$ENVF'"
  next "Add your OpenRouter key (https://openrouter.ai/keys) to $ENVF as  OPENROUTER_API_KEY=sk-or-…"
fi
hooks add

say "App"
if [ $BUILD = 1 ]; then run "$V/pet/build.sh"; [ $DRY = 1 ] || ok "VoicePet.app built and signed"
else ok "build skipped (--no-build)"; fi

if [ $LOGIN = 1 ]; then
  say "Start at login"
  [ $DRY = 1 ] || mkdir -p "$HOME/Library/LaunchAgents"
  for L in $AGENTS; do
    DST="$HOME/Library/LaunchAgents/$L.plist"; NEW=$(mktemp)
    sed "s#__HOME__#$HOME#g" "$V/system/$L.plist" > "$NEW"
    if cmp -s "$NEW" "$DST" && launchctl print "$GUI/$L" >/dev/null 2>&1; then ok "$L (running)"; rm -f "$NEW"; continue; fi
    run mv "$NEW" "$DST"; [ $DRY = 1 ] && rm -f "$NEW"
    run launchctl bootout "$GUI/$L" 2>/dev/null || true
    run launchctl bootstrap "$GUI" "$DST"
    [ $DRY = 1 ] || ok "$L started"
  done
fi

say "Next"
[ -z "$NEXT" ] || printf '%s' "$NEXT" | sed 's/^/  → /'
cat <<'TXT'
  → System Settings › Privacy & Security › Accessibility: turn on VoicePet (hotkeys, reading selections).
    macOS asks for the microphone the first time you hold a number key; meetings that record Mac audio
    also ask for System Audio Recording.
  → Click + at the bottom right of your screen › New Claude session. Then hold 1, talk, and let go.
TXT
