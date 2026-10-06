#!/bin/bash
# PreToolUse hook: speak what Claude just wrote before running a tool (its own narration).
[ "$VOICE_SESSION" = 1 ] && { cat >/dev/null; exit 0; }   # voice session speaks via its speak tool
source "$HOME/.claude/voice/lib.sh"
MSG=$(printf '%s' "$IN" | python3 "$DIR/voice_text.py" pretool "${MAX_SENTENCES:-2}")
[ -n "$MSG" ] && { nohup "$DIR/speak" "$MSG" >/dev/null 2>&1 & }
exit 0
