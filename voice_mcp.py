#!/usr/bin/env python3
"""Minimal MCP stdio server exposing one tool, `speak`, which queues text for the voice server to say aloud."""
import json, os, subprocess, sys, time, urllib.request

SPOOL = os.path.expanduser("~/.claude/voice/spool")

def post(text):
    who = os.environ.get("VOICE_SESSION_NAME", "voice")          # which orb is speaking
    urllib.request.urlopen(urllib.request.Request(f"http://127.0.0.1:5123/say?kind=say&s={who}", data=text.encode()), timeout=3)

def deliver(text):
    """Send to the voice server; if it's down, (re)start it via launchd and wait up to ~30 s
    (it loads models on start). If it still isn't up, spool the line: the server plays it on startup."""
    try:
        post(text); return "Queued for speech."
    except Exception:
        pass
    subprocess.run(["launchctl", "kickstart", f"gui/{os.getuid()}/com.claude.kitten-tts"], capture_output=True)
    for _ in range(60):
        time.sleep(0.5)
        try:
            post(text); return "Voice server was down; restarted it and queued the line."
        except Exception:
            continue
    os.makedirs(SPOOL, exist_ok=True)
    with open(os.path.join(SPOOL, f"{time.time():.3f}.txt"), "w") as f:
        f.write(text)
    return "Voice server is starting; the line is saved and will be spoken when it is up."

TOOL = {
    "name": "speak",
    "description": "Say something out loud to the user. This is your ONLY channel to the user: they hear it, "
                   "they do not read the terminal. Write for the ear: 1-3 short sentences, no markdown, URLs, "
                   "paths or code. Returns immediately; calls are played in order.",
    "inputSchema": {"type": "object", "properties": {"text": {"type": "string", "description": "Exactly what to say."}},
                    "required": ["text"]},
}

def reply(id_, result=None, error=None):
    msg = {"jsonrpc": "2.0", "id": id_}
    msg.update({"error": error} if error else {"result": result})
    sys.stdout.write(json.dumps(msg) + "\n"); sys.stdout.flush()

for line in sys.stdin:
    try:
        req = json.loads(line)
    except Exception:
        continue
    method, id_ = req.get("method"), req.get("id")
    if id_ is None:
        continue                                  # notifications need no answer
    if method == "initialize":
        reply(id_, {"protocolVersion": req.get("params", {}).get("protocolVersion", "2025-06-18"),
                    "capabilities": {"tools": {}}, "serverInfo": {"name": "voice", "version": "1.0"}})
    elif method == "tools/list":
        reply(id_, {"tools": [TOOL]})
    elif method == "tools/call":
        text = (req.get("params", {}).get("arguments") or {}).get("text", "").strip()
        reply(id_, {"content": [{"type": "text", "text": deliver(text)}]})
    elif method == "ping":
        reply(id_, {})
    else:
        reply(id_, error={"code": -32601, "message": f"unknown method {method}"})
