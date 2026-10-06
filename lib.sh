# Shared by hook scripts: reads hook JSON into $IN and exits unless this session may speak.
DIR="$HOME/.claude/voice"
[ -f "$DIR/off" ] && exit 0
source "$DIR/config"
IN=$(cat)
if [ -n "$VOICE_ONLY_IN" ] && [ "$VOICE_SESSION" != 1 ]; then   # the voice session reports from any folder
  CWD=$(jq -r '.cwd // ""' <<<"$IN")
  OK=0; IFS='|' read -ra DIRS <<<"$VOICE_ONLY_IN"
  for d in "${DIRS[@]}"; do [[ "$CWD" == "$d"* ]] && OK=1; done
  [ $OK = 1 ] || exit 0
fi
