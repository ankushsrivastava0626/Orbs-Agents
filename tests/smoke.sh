#!/bin/bash
# End-to-end check of the voice server's main paths (plays a few short lines aloud; costs well under $0.01).
#   tests/smoke.sh          run everything
# Uses the server on 127.0.0.1:5123; leaves no cards, meetings or settings changed behind.
S=localhost:5123; pass=0; fail=0
ok()  { echo "  ok    $1"; pass=$((pass+1)); }
bad() { echo "  FAIL  $1"; fail=$((fail+1)); }
j()   { /usr/bin/python3 -c "import json,sys;d=json.load(sys.stdin);print($1)"; }

echo "server"
t=$( { /usr/bin/time -p curl -s -m 3 $S/status >/dev/null; } 2>&1 | awk '/^real/{print $2}')
[ -n "$t" ] && ok "status answers (${t}s)" || { bad "status not answering"; exit 1; }
for i in 1 2 3 4 5; do curl -s -m 1 $S/status >/dev/null || bad "status slow or failing on poll $i"; done

echo "settings"
before_stt=$(curl -s $S/status | j "d.get('stt_engine')"); before_v=$(curl -s $S/status | j "d.get('voice_engine')")
[ "$before_stt" = cloud ] && [ "$before_v" = fish ] && ok "engines reported (stt=$before_stt, voice=$before_v)" || bad "engines: stt=$before_stt voice=$before_v"
curl -s -X POST "$S/settings?ENGINE=bogus" | grep -q '"ENGINE": "fish"' && ok "bad setting ignored" || bad "bad setting not ignored"

echo "Joe's voice"
curl -s -X POST "$S/?kind=report" -d "Testing, sir." >/dev/null
spoke=0; for i in $(seq 1 60); do [ "$(curl -s $S/status | j "int(d['speaking'])")" = 1 ] && spoke=1; [ $spoke = 1 ] && [ "$(curl -s $S/status | j "int(d['speaking'])")" = 0 ] && break; sleep 0.1; done
[ $spoke = 1 ] && ok "spoke a line" || bad "never started speaking"

echo "task board"
curl -s -X POST $S/task/record -d '{"text":"new"}' >/dev/null; sleep 2.5
say -r 170 "Smoke test. Buy milk on Friday."
curl -s -X POST $S/task/record -d '{"text":"stop"}' >/dev/null
for i in $(seq 1 60); do curl -s $S/task | j "0 if not d['rec']['transcribing'] and not d['rec']['recording'] else 1" | grep -q 0 && break; sleep 0.3; done
txt=$(curl -s $S/task | j "d['cards'][-1]['original']"); id=$(curl -s $S/task | j "d['cards'][-1]['id']")
echo "$txt" | grep -qi "milk" && ok "recorded and transcribed: $txt" || bad "task text: '$txt'"
curl -s -X POST $S/task/delete -d "{\"id\":\"$id\"}" >/dev/null
curl -s $S/task | j "any(c['id']=='$id' for c in d['cards'])" | grep -q False && ok "test card deleted" || bad "test card left behind"

echo "result: $pass ok, $fail failed"
[ $fail = 0 ]
