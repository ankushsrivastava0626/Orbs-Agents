#!/bin/bash
# Notification hook: speak permission requests / "waiting for input".
source "$HOME/.claude/voice/lib.sh"
MSG=$(jq -r '.message // empty' <<<"$IN")
[ -n "$MSG" ] && nohup "$DIR/speak" "$MSG" >/dev/null 2>&1 &
exit 0
