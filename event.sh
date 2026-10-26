#!/bin/bash
# Tell the pet overlay what Claude is doing. usage: event.sh <Prompt|Step|Stop>  (hook JSON on stdin)
[ "$VOICE_SESSION" = 1 ] || { cat >/dev/null; exit 0; }   # only voice sessions (orbs) report; the desktop app stays out
# Custom-command orbs get these hooks passed in (--settings, arg 2 = "flag"); skip the copy from
# ~/.claude/settings.json so their events aren't sent twice.
[ "$VOICE_HOOKS_FLAG" = 1 ] && [ "$2" != flag ] && { cat >/dev/null; exit 0; }
source "$HOME/.claude/voice/lib.sh"
case "$1" in
  Prompt) BODY='{"claude":"working","step":"Thinking…"}' ;;
  Stop)   BODY='{"claude":"idle","step":""}' ;;
  Step)   T=$(jq -r '.tool_name // ""' <<<"$IN" | sed -E 's/^mcp__[^_]+(_[^_]+)*__//; s/^mcp__//')
          D=$(jq -r '.tool_input.description // .tool_input.url // .tool_input.action // .tool_input.query // ""' <<<"$IN" | cut -c1-60)
          BODY=$(jq -cn --arg s "$T${D:+: $D}" '{"claude":"working","step":$s}') ;;
esac
[ "$VOICE_SESSION" = 1 ] && BODY=$(jq -c --arg s "${VOICE_SESSION_NAME:-voice}" '. + {voice: true, session: $s}' <<<"$BODY")   # lets auto mode track the voice session
curl -s -m 1 -X POST --data-binary "$BODY" http://127.0.0.1:5123/event >/dev/null 2>&1
if [ "$1" = Stop ] && [ "$VOICE_HOOKS_FLAG" = 1 ]; then              # model didn't speak: read its reply out
  SAY=$(/usr/bin/python3 "$HOME/.claude/voice/stop_fallback.py" <<<"$IN")
  [ -n "$SAY" ] && curl -s -m 2 -X POST --data-binary "$SAY" "http://127.0.0.1:5123/say?kind=say&s=${VOICE_SESSION_NAME:-voice}" >/dev/null 2>&1
fi
exit 0
