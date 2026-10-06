#!/bin/bash
# PostToolUse hook: one short spoken line per browser action.
source "$HOME/.claude/voice/lib.sh"
TOOL=$(jq -r '.tool_name // ""' <<<"$IN")
ACTION=$(jq -r '.tool_input.action // ""' <<<"$IN")
URL=$(jq -r '.tool_input.url // ""' <<<"$IN")
TEXT=$(jq -r '.tool_input.text // ""' <<<"$IN")
QUERY=$(jq -r '.tool_input.query // ""' <<<"$IN")

case "$TOOL" in
  *__navigate)
    case "$URL" in
      back) MSG="Going back" ;; forward) MSG="Going forward" ;;
      *) HOST=$(sed -E 's#^[a-z]+://##; s#/.*##; s#^www\.##' <<<"$URL"); MSG="Opening $HOST" ;;
    esac ;;
  *__computer)
    case "$ACTION" in
      left_click|double_click|triple_click) MSG="Clicking" ;;
      type) MSG="Typing" ;;
      key) MSG="Pressing $TEXT" ;;
      scroll|scroll_to) MSG="Scrolling" ;;
      left_click_drag) MSG="Dragging" ;;
      *) exit 0 ;;   # screenshots, waits, hovers, zooms: silent
    esac ;;
  *__find) MSG="Looking for ${QUERY:0:40}" ;;
  *__form_input) MSG="Filling in a field" ;;
  *__get_page_text|*__read_page) MSG="Reading the page" ;;
  *__tabs_create*) MSG="Opening a new tab" ;;
  *) exit 0 ;;
esac

# Throttle: repeated identical lines within 4s are skipped (e.g. many scrolls)
STATE=/tmp/claude-voice.last; NOW=$(date +%s)
if [ -f "$STATE" ]; then
  read -r LAST_T LAST_M < "$STATE"
  [ "$LAST_M" = "$MSG" ] && [ $((NOW - LAST_T)) -lt 4 ] && exit 0
fi
echo "$NOW $MSG" > "$STATE"

nohup "$DIR/speak" "$MSG" >/dev/null 2>&1 &
exit 0
