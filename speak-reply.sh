#!/bin/bash
# Stop hook: speak the final reply unless it was already spoken mid-turn.
[ "$VOICE_SESSION" = 1 ] && { cat >/dev/null; exit 0; }   # voice session speaks via its speak tool
source "$HOME/.claude/voice/lib.sh"
N=${MAX_SENTENCES:-2}; [ "$ENGINE" = "gemini" ] && N=0      # Joe gets the whole reply and summarises it himself
MSG=$(printf '%s' "$IN" | python3 "$DIR/voice_text.py" stop "$N")
[ -n "$MSG" ] && { SPEAK_KIND=report nohup "$DIR/speak" "$MSG" >/dev/null 2>&1 & }
exit 0
