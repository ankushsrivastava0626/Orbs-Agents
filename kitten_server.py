"""Local KittenTTS speech server: keeps the model loaded and owns the speech queue.

POST /say   body=text  -> queued, spoken in order (sentence-pipelined)
POST /stop             -> stop now and drop everything queued
GET  /health
"""
import signal, sys
import os, re, queue, sys, threading
sys.path.insert(0, os.path.expanduser("~/.claude/voice"))
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DIR = os.path.expanduser("~/.claude/voice")
PORT = 5123

def config():
    cfg = {}
    for line in open(os.path.join(DIR, "config")):
        line = line.split("#", 1)[0].strip()
        if "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip().strip('"')
    return cfg

os.environ.setdefault("HF_HUB_OFFLINE", "1")   # Kitten/Kokoro weights are already in the HF cache
MODEL_NAME = config().get("KITTEN_MODEL", "KittenML/kitten-tts-nano-0.8-int8")
model = None                                    # local voices load in the background so the server is up at once
models_ready = threading.Event()

import numpy as np
import sounddevice as sd

import json, time
STATUS = {"last_said": {}, "muted_sessions": [], "captions": [], "target": "voice", "target_kind": "claude", "sessions": {}, "speaking_session": "",
          "pending_note": None, "saved_note": None, "notes": False, "out_level": 0.0, "problem_at": 0, "auto": False, "ptt": False, "voice_claude": "idle", "voice_claude_at": 0,
          "listening": False, "level": 0.0, "transcribing": False, "heard": "", "heard_at": 0,
          "speaking": False, "spoken": "", "claude": "idle", "step": "", "claude_at": 0}

SR = 24000
GAP = np.zeros(int(SR * 0.12), dtype=np.float32)   # short natural pause between sentences
jobs = queue.Queue()
gen = 0              # bumped by /stop; in-flight work checks it and bails

def sentences(text):
    parts = re.split(r"(?<=[.!?])\s+", text.strip())
    return [p for p in parts if p]

def trim(a, thresh=0.01, pad=0.04):
    idx = np.where(np.abs(a) > thresh)[0]
    if len(idx) == 0:
        return a[:0]
    p = int(SR * pad)
    return a[max(0, idx[0] - p): idx[-1] + p]

def synth(text, cfg):
    models_ready.wait()
    return trim(np.asarray(model.generate(text, voice=cfg.get("KITTEN_VOICE", "Jasper"),
                speed=float(cfg.get("KITTEN_SPEED", "1.0")), clean_text=True), dtype=np.float32))

from gemini_voice import GeminiVoice, tts as gemini_tts
joe = GeminiVoice(os.path.join(DIR, "persona.txt"), on_said=lambda t: STATUS.update(spoken=t))
tts_player = None

def set_tts_player(p):
    global tts_player
    tts_player = p

def abort_all():
    sd.stop(); joe.abort()
    STATUS["speaking"] = False      # pet clears now, even while a cancelled Gemini turn drains
    p = tts_player
    if p: p.stop()

from gemini_voice import Player
import gemini_voice
gemini_voice.LEVEL_CB = lambda v: STATUS.__setitem__("out_level", v)
kokoro_pipes = {}

def load_models():
    global model, KPipeline
    t = time.time()
    try:
        from kittenml import KittenTTS
        model = KittenTTS(MODEL_NAME)
        from kokoro import KPipeline as K
        KPipeline = K
        kokoro_pipes["a"] = KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")
        keep_resident.pin_weights(getattr(kokoro_pipes["a"], "model", None))   # Joe's voice stays in RAM
    finally:
        models_ready.set()
        print(f"local voices loaded ({time.time() - t:.1f}s)", flush=True)

import keep_resident                             # speech-to-text model + program stay in RAM (8 GB Mac)
keep_resident.start()
threading.Thread(target=load_models, daemon=True).start()

def kokoro_pipe(voice):
    """Voice prefix picks the accent: a* American, b* British. Pipelines share one model."""
    models_ready.wait()
    lang = voice[0] if voice[:1] in ("a", "b") else "a"
    if lang not in kokoro_pipes:
        kokoro_pipes[lang] = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M", model=kokoro_pipes["a"].model)
    return kokoro_pipes[lang]

def kokoro_say(text, cfg, still_current):
    """Speak with Kokoro, streaming: each chunk plays as soon as it is generated."""
    player = Player(1.0)
    set_tts_player(player)
    try:
        voice = cfg.get("KOKORO_VOICE", "bm_george")
        for _, _, audio in kokoro_pipe(voice)(text, voice=voice,
                                  speed=float(cfg.get("KOKORO_SPEED", "1.2"))):
            if not still_current() or player.stopped:
                break
            pcm = (np.clip(np.asarray(audio, dtype=np.float32), -1, 1) * 32767).astype(np.int16).tobytes()
            player.write(pcm)
    finally:
        set_tts_player(None)
        player.close()

gemini_blocked_until = 0.0

def gemini_ok():
    return time.time() >= gemini_blocked_until and joe.available()

def note_gemini_error(e):
    global gemini_blocked_until
    STATUS["problem_at"] = time.time()
    msg = repr(e)
    if any(k in msg for k in ("429", "RESOURCE_EXHAUSTED", "quota", "1011")):
        gemini_blocked_until = time.time() + 1800     # quota hit: use Kokoro for 30 min, then retry
        print("gemini quota exhausted; using Kokoro for 30 min", flush=True)
    else:
        print("gemini failed:", msg[:300], flush=True)

def guarded(fn, limit):
    """Run fn in a thread; if it hasn't finished within `limit` seconds, stop its audio and move on."""
    box = {}
    def run():
        try:
            box["ok"] = fn()
        except Exception as e:
            note_gemini_error(e)
    t = threading.Thread(target=run, daemon=True)
    t.start(); t.join(limit)
    if t.is_alive():
        print(f"voice job timed out after {limit}s; skipping", flush=True)
        STATUS["problem_at"] = time.time()
        p = tts_player
        if p: p.stop()
        joe.abort()
        return False
    return box.get("ok", False)

audio_lock = threading.Lock()

def refresh_audio():
    """PortAudio reads the device list once; after AirPods/speakers switch, re-read it."""
    with audio_lock:
        try:
            sd._terminate(); sd._initialize()
            print("audio devices refreshed; output:", sd.query_devices(kind="output")["name"], flush=True)
        except Exception as e:
            print("audio refresh failed:", repr(e), flush=True)

import ctypes as _ct
_ca = _ct.CDLL("/System/Library/Frameworks/CoreAudio.framework/CoreAudio")
class _Addr(_ct.Structure):
    _fields_ = [("sel", _ct.c_uint32), ("scope", _ct.c_uint32), ("elem", _ct.c_uint32)]
_last_out = [None]

def default_output_id():
    """The Mac's current output device (what the volume keys control), straight from CoreAudio."""
    a = _Addr(0x644F7574, 0x676C6F62, 0)                  # 'dOut', 'glob', main element
    dev, size = _ct.c_uint32(0), _ct.c_uint32(4)
    err = _ca.AudioObjectGetPropertyData(_ct.c_uint32(1), _ct.byref(a), 0, None, _ct.byref(size), _ct.byref(dev))
    return dev.value if err == 0 else None

def follow_output_device():
    """Earphones plugged in / AirPods connected since we last spoke: PortAudio still points at the old
    device, so Joe would come out of the speakers (and ignore the volume keys). Re-read devices first."""
    cur = default_output_id()
    if cur is not None and _last_out[0] is not None and cur != _last_out[0] and not PTT.get("down"):
        refresh_audio()
    if cur is not None: _last_out[0] = cur

_last_out[0] = default_output_id()                      # the device PortAudio picked up at start

def is_audio_error(e):
    return e is not None and "PortAudio" in repr(e)

def speak_gemini(text, kind, cfg, my_gen):
    """Gemini Live; on an audio-device error refresh devices and try once more. Returns True if spoken."""
    for attempt in (1, 2):
        joe.last_error = None
        ok = guarded(lambda: joe.speak(text, kind, lambda: my_gen == gen,
                       cfg.get("GEMINI_MODEL", "models/gemini-3.8-live"), cfg.get("GEMINI_VOICE", "Orus"),
                       float(cfg.get("GEMINI_SPEED", "1.0"))), 20 + len(text) / 8 if kind == "SAY" else 60)
        if ok or my_gen != gen:
            return True
        if is_audio_error(joe.last_error) and attempt == 1:
            refresh_audio(); continue
        if joe.last_error is not None and not is_audio_error(joe.last_error):
            note_gemini_error(joe.last_error)          # quota etc.: Kokoro for a while
        return False
    return False

def speak_kokoro(text, cfg, my_gen):
    for attempt in (1, 2):
        try:
            kokoro_say(text, cfg, lambda: my_gen == gen)
            return True
        except Exception as e:
            print("kokoro failed:", repr(e)[:200], flush=True)
            if is_audio_error(e) and attempt == 1:
                refresh_audio(); continue
            return False
    return False

LAST_SAID = os.path.join(DIR, "last_said.json")
try: STATUS["last_said"].update(json.load(open(LAST_SAID)))
except Exception: pass

def seed_last_said():
    """Orbs with nothing remembered (e.g. before this was saved): their last spoken line, from their transcript."""
    import glob
    try: orbs = json.load(open(os.path.join(DIR, "orbs.json")))
    except Exception: return
    for o in orbs:
        name, sid = o.get("name"), o.get("id")
        if o.get("kind") != "claude" or not sid or name in STATUS["last_said"]: continue
        files = glob.glob(os.path.expanduser("~/.claude*/projects/*/" + sid + ".jsonl"))
        if not files: continue
        text, at = "", 0
        for raw in open(files[0], errors="ignore"):
            if '"speak"' not in raw and "speak" not in raw: continue
            try: e = json.loads(raw)
            except Exception: continue
            for b in (e.get("message") or {}).get("content") or []:
                if isinstance(b, dict) and b.get("type") == "tool_use" and b.get("name", "").endswith("speak"):
                    t = (b.get("input") or {}).get("text", "")
                    if t: text, at = t, os.path.getmtime(files[0])
        if text:
            STATUS["last_said"][name] = {"id": f"s{at:.3f}", "session": name, "text": text, "at": at}

seed_last_said()

def worker():
    while True:
        my_gen, text, kind, who = jobs.get()
        try: follow_output_device()
        except Exception as e: print("output check failed:", repr(e), flush=True)
        STATUS["speaking_session"] = who
        if kind == "SAY":                                     # remember each orb's last reply (hover shows it)
            STATUS["last_said"][who or "voice"] = {"id": f"s{time.time():.3f}", "session": who or "voice",
                                                   "text": text, "at": time.time()}
            try: json.dump(STATUS["last_said"], open(LAST_SAID, "w"))   # kept through server restarts
            except OSError: pass
        if kind == "SAY" and (who or "voice") in STATUS["muted_sessions"]:
            # muted orb: show the reply as text instead of speaking it
            STATUS["captions"] = (STATUS["captions"] + [{"id": f"{time.time():.3f}", "session": who or "voice",
                                                          "text": text, "at": time.time()}])[-10:]
            continue
        if my_gen != gen:
            continue
        cfg = config()
        engine = cfg.get("ENGINE", "gemini")
        try:
            if engine == "gemini" and gemini_ok():
                STATUS.update(speaking=True, spoken=text if kind == "SAY" else "")
                if speak_gemini(text, kind, cfg, my_gen):
                    continue
                STATUS["problem_at"] = time.time()     # amber dot: Gemini failed, using the fallback voice
            if engine in ("gemini", "kokoro"):
                if kind != "SAY":                    # hook-read replies/steps: keep them short without Joe
                    text = " ".join(sentences(text)[:int(cfg.get("MAX_SENTENCES", "2"))])
                if engine == "gemini":
                    STATUS["problem_at"] = time.time()
                STATUS.update(speaking=True, spoken=text)
                if not speak_kokoro(text, cfg, my_gen):
                    STATUS["problem_at"] = time.time()
                    print("dropped line (no working voice):", text[:80], flush=True)
                continue
            # legacy Kitten engine
            clips = []
            for snt in sentences(text):
                try:
                    clips += [synth(snt, cfg), GAP]
                except Exception as e:
                    print("synth error:", e, flush=True)
            if not clips or my_gen != gen:
                continue
            STATUS.update(speaking=True, spoken=text)
            sd.play(np.concatenate(clips[:-1]), SR)
            sd.wait()
        except Exception as e:
            print("worker error:", repr(e)[:200], flush=True)
        finally:
            STATUS["speaking"] = False

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _ok(self, body=b"ok"):
        self.send_response(200); self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        if self.path == "/status":
            STATUS["resident_mb"] = round(keep_resident.stats["files_mb"] + keep_resident.stats["weights_mb"])
            self._ok(json.dumps(STATUS).encode())
        elif self.path == "/task":           # the task board polls this
            self._ok(json.dumps(task_view()).encode())
        elif self.path == "/meeting/live":   # the meeting board polls this while it's on; live passes run only then
            LIVE["seen"] = time.time()
            self._ok(json.dumps(meeting_live_view()).encode())
        else:
            self._ok(MODEL_NAME.encode())
    def do_POST(self):
        global gen
        body = self.rfile.read(int(self.headers.get("Content-Length", 0))).decode("utf-8", "replace")
        if self.path == "/event":       # from Claude hooks: {"claude": "working"|"idle", "step": "...", "voice": true}
            try:
                ev = json.loads(body)
                STATUS.update({k: v for k, v in ev.items() if k in ("claude", "step")}, claude_at=time.time())
                if ev.get("voice"):
                    name = ev.get("session") or "voice"
                    STATUS["sessions"][name] = {"state": ev.get("claude", "idle"), "step": ev.get("step", ""), "at": time.time()}
                    if name == STATUS["target"]:
                        STATUS.update(voice_claude=ev.get("claude", "idle"), voice_claude_at=time.time())
            except Exception:
                pass
            self._ok(); return
        if self.path.split("?")[0] in ("/claude/stop", "/claude/quit", "/claude/show"):
            import subprocess
            m = re.search(r"[?&]s=([^&]+)", self.path)
            target = m.group(1) if m else (STATUS.get("target") or "voice")
            gen += 1; abort_all()                                   # silence Joe either way
            if self.path.startswith("/claude/stop"):                # interrupt the current task (Esc twice)
                for _ in range(2):
                    subprocess.run([TMUX, "send-keys", "-t", target, "Escape"]); time.sleep(0.15)
            elif self.path.startswith("/claude/quit"):              # end the voice session entirely
                subprocess.run([TMUX, "kill-session", "-t", target])
            else:                                                   # open a Terminal window on it
                if subprocess.run([TMUX, "has-session", "-t", target], capture_output=True).returncode == 0:
                    subprocess.run(["osascript", "-e", f'tell application "Terminal" to do script "{TMUX} attach -t {target}"'])
            STATUS.update(voice_claude="idle", voice_claude_at=time.time(), claude="idle", step="")
            if not self.path.startswith("/claude/show"):          # the orb itself reads its own entry
                STATUS["sessions"][target] = {"state": "idle", "step": "", "at": time.time()}
            print("menu:", self.path, flush=True)
            self._ok(); return
        if self.path == "/note/propose":     # add a note from text (same 1 s show-then-save flow)
            if body.strip(): propose_note(body.strip())
            self._ok(); return
        if self.path.startswith("/note/"):   # pet: {"id": ..., "text": ...}
            try: ev = json.loads(body or "{}")
            except Exception: ev = {}
            with note_lock:
                n = STATUS["pending_note"]
                ok = bool(n and n["id"] == ev.get("id"))
                if ok and self.path == "/note/hold":
                    n["held"] = True                   # user clicked: wait for their edit
                elif ok and self.path == "/note/commit":
                    finish_note(n["id"], ev.get("text"), save=True)
                elif ok and self.path == "/note/discard":
                    finish_note(n["id"], None, save=False)
            self._ok(json.dumps({"ok": ok}).encode()); return
        if self.path == "/type":             # typed message from an orb's input field {"name","kind","text"}
            try:
                ev = json.loads(body); text = (ev.get("text") or "").strip()
                if text:
                    STATUS.update(target=ev.get("name", "voice"), target_kind=ev.get("kind", "claude"))
                    def go():
                        send_to_claude(text)
                        STATUS.update(heard=text, heard_at=time.time())
                    threading.Thread(target=go, daemon=True).start()
            except Exception:
                pass
            self._ok(); return
        if self.path == "/mute":             # {"session": "voice-2", "on": true|false}: replies become text cards
            try:
                ev = json.loads(body); name = ev.get("session", "voice")
                on = ev.get("on", name not in STATUS["muted_sessions"])
                muted = [n for n in STATUS["muted_sessions"] if n != name] + ([name] if on else [])
                STATUS["muted_sessions"] = muted
                if on and STATUS.get("speaking_session") == name:
                    gen += 1; abort_all()                          # stop it mid-sentence
            except Exception:
                pass
            self._ok(json.dumps({"muted": STATUS["muted_sessions"]}).encode()); return
        if self.path.startswith("/task/"):       # task boards: record / new / ask Mercury / edit / delete / hide / show all
            try: ev = json.loads(body or "{}")
            except Exception: ev = {}
            task_post(self.path, ev)
            self._ok(json.dumps(task_view()).encode()); return
        if self.path == "/meeting/open":      # pet's Previous meetings menu: {"text": folder}
            try: f = json.loads(body or "{}").get("text") or ""
            except Exception: f = ""
            self._ok(json.dumps({"ok": meeting_open(f)}).encode()); return
        if self.path in ("/meeting/prompt", "/meeting/ask"):   # meeting board: the prompt for each line / one question
            try: v = (json.loads(body or "{}").get("text") or "").strip()
            except Exception: v = ""
            if self.path == "/meeting/prompt":
                LIVE["prompt"] = v; self._ok(); return
            self._ok(json.dumps({"answer": meeting_ask(v) if v else ""}).encode()); return
        if self.path == "/meeting":          # pet: right Option double-tap → toggle meeting recording
            (meeting_stop if MEETING["on"] else meeting_start)()
            self._ok(json.dumps({"meeting": MEETING["on"], "folder": MEETING["folder"]}).encode()); return
        if self.path == "/ptt":              # pet: an orb's speak hotkey went down/up {"name","kind","down"}
            try:
                ev = json.loads(body)
                if ev.get("cancel"):              # it was a tap or a shortcut (Ctrl-C…), not a hold to talk
                    PTT.update(cancel=True, down=False)
                    if PTT.get("prev"): STATUS.update(target=PTT["prev"][0], target_kind=PTT["prev"][1])
                    self._ok(); return
                if ev.get("down") and ev.get("kind") == "notes":   # left Option: a note, whatever orb is selected
                    PTT.update(cancel=False, notes=True, prev=None)
                elif ev.get("down"):
                    PTT.update(cancel=False, notes=False, prev=(STATUS.get("target"), STATUS.get("target_kind")))
                    STATUS.update(target=ev.get("name", "voice"), target_kind=ev.get("kind", "claude"))
                    st = STATUS["sessions"].get(STATUS["target"], {})
                    STATUS.update(voice_claude=st.get("state", "idle"), voice_claude_at=st.get("at", 0))
                PTT["down"] = bool(ev.get("down"))
            except Exception:
                PTT["down"] = False
            self._ok(); return
        if self.path == "/target":           # which session your voice goes to: {"name": "voice-2", "kind": "claude"|"codex"}
            try:
                ev = json.loads(body)
                STATUS.update(target=ev.get("name", "voice"), target_kind=ev.get("kind", "claude"))
                st = STATUS["sessions"].get(STATUS["target"], {})
                STATUS.update(voice_claude=st.get("state", "idle"), voice_claude_at=st.get("at", 0))
            except Exception:
                pass
            self._ok(json.dumps({"target": STATUS["target"]}).encode()); return
        if self.path == "/notes":
            try: STATUS["notes"] = bool(json.loads(body)["on"])
            except Exception: STATUS["notes"] = not STATUS["notes"]
            print("notes mode", "ON" if STATUS["notes"] else "OFF", flush=True)
            self._ok(json.dumps({"notes": STATUS["notes"], "file": notes_file()}).encode()); return
        if self.path == "/auto":
            try: STATUS["auto"] = bool(json.loads(body)["on"])
            except Exception: STATUS["auto"] = not STATUS["auto"]
            if not STATUS["auto"]:
                STATUS.update(listening=False, level=0.0)
            print("auto mode", "ON" if STATUS["auto"] else "OFF", flush=True)
            if STATUS["auto"] and not STATUS["notes"]:
                threading.Thread(target=ensure_voice_session, daemon=True).start()
            self._ok(json.dumps({"auto": STATUS["auto"]}).encode()); return
        if self.path == "/stop":
            gen += 1
            abort_all()
        elif body.strip():
            kind = "REPORT" if "kind=report" in self.path else "SAY" if "kind=say" in self.path else "STEP"
            m = re.search(r"[?&]s=([^&]+)", self.path)
            jobs.put((gen, body, kind, m.group(1) if m else ""))
        self._ok()

STT_CLI = "/Applications/MacParakeet.app/Contents/MacOS/macparakeet-cli"
STT_DB = os.path.join(DIR, "stt.db")      # keep voice commands out of MacParakeet's own history

def trim_stt_db():
    """MacParakeet saves every transcription in its database, and gets slower as it grows (36 s per
    command at 5 MB, 0.3 s fresh). We don't need that history, so start a new one once it's big."""
    try:
        if os.path.getsize(STT_DB) > 1_500_000:
            for ext in ("", "-wal", "-shm"):
                if os.path.exists(STT_DB + ext): os.replace(STT_DB + ext, STT_DB + ".old" + ext)
            print("stt: started a fresh transcription database", flush=True)
    except OSError:
        pass

def transcribe(path):
    import subprocess
    trim_stt_db()
    t = time.time()
    try:
        out = subprocess.run([STT_CLI, "transcribe", path, "--format", "json", "--speaker-detection", "off",
                              "--engine", "parakeet", "--database", STT_DB],
                             capture_output=True, text=True, timeout=120).stdout
    except subprocess.TimeoutExpired:
        print("stt: timed out after 120 s", flush=True); return ""
    if time.time() - t > 5: print(f"stt: slow transcription ({time.time() - t:.1f}s)", flush=True)
    try:
        return (json.loads(out).get("rawTranscript") or "").strip()
    except Exception:
        return ""

TMUX = "/opt/homebrew/bin/tmux"
session_lock = threading.Lock()

def ensure_voice_session():
    """If the tmux voice session isn't running (e.g. after a Mac restart), start it, open a Terminal
    window on it, and wait until Claude's prompt is ready. Returns True when it can take input."""
    import subprocess
    target = config().get("VOICE_TMUX_TARGET", "voice")
    def running():
        return subprocess.run([TMUX, "has-session", "-t", target], capture_output=True).returncode == 0
    def ready():
        out = subprocess.run([TMUX, "capture-pane", "-pt", target], capture_output=True, text=True).stdout
        return "\u276f" in out                     # Claude Code's input prompt
    with session_lock:
        if running() and ready():
            return True
        if not running():
            print("voice session not running: starting it", flush=True)
            subprocess.run([os.path.join(DIR, "start-voice-session.sh")], capture_output=True)
            subprocess.run(["open", "-a", "Terminal", os.path.join(DIR, "attach-voice.command")])
        for _ in range(90):                          # Claude takes a few seconds to boot
            if running() and ready():
                time.sleep(0.5)
                return True
            time.sleep(0.5)
        print("voice session did not become ready", flush=True)
        return False

CODEX_ROOT = "/Users/kush/Documents/Codex/2026-10-04/can-x20/outputs/codex-voice-assistant"

def codex_use_orb(token):
    """Several Codex orbs share one Codex server, which holds one conversation at a time: switch it to the
    conversation of the orb you're talking to before sending."""
    import urllib.request
    try:
        orbs = json.load(open(os.path.join(DIR, "orbs.json")))
        want = next((o.get("id") for o in orbs if o.get("name") == STATUS.get("target")), None)
        if not want: return
        h = {"Authorization": "Bearer " + token, "Content-Type": "application/json"}
        cur = json.load(urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:5124/status", headers=h), timeout=3))
        if cur.get("thread_id") != want:
            urllib.request.urlopen(urllib.request.Request("http://127.0.0.1:5124/sessions/resume",
                                   data=json.dumps({"session": want}).encode(), headers=h), timeout=20)
            print("codex: switched to", STATUS.get("target"), want, flush=True)
    except Exception as e:
        print("codex switch failed:", repr(e), flush=True)

def send_to_codex(text):
    import urllib.request
    try:
        token = open(os.path.join(CODEX_ROOT, "runtime/token")).read().strip()
        codex_use_orb(token)
        req = urllib.request.Request("http://127.0.0.1:5124/input", data=json.dumps({"text": text}).encode(),
                                     headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
        urllib.request.urlopen(req, timeout=3)
        print("sent to codex:", text, flush=True)
    except Exception as e:
        print("codex input failed:", repr(e), flush=True); STATUS["problem_at"] = time.time()

def send_to_claude(text):
    import subprocess
    if STATUS.get("target_kind") == "codex":
        send_to_codex(text); return
    target = STATUS.get("target") or "voice"
    if target != "voice":                                  # extra sessions: must already be running
        if subprocess.run([TMUX, "has-session", "-t", target], capture_output=True).returncode != 0:
            print("session", target, "is not running", flush=True); STATUS["problem_at"] = time.time(); return
    elif not ensure_voice_session():
        STATUS["problem_at"] = time.time()
        return
    st = STATUS["sessions"].get(target, {})
    if st.get("state") == "working" and time.time() - st.get("at", 0) < 1800:
        subprocess.run([TMUX, "send-keys", "-t", target, "Escape"])   # a new command interrupts the running task
        time.sleep(0.6)
        print("interrupted", target, "for a new command", flush=True)
    subprocess.run([TMUX, "send-keys", "-t", target, "-l", text])
    subprocess.run([TMUX, "send-keys", "-t", target, "Enter"])
    print("sent:", text, "->", target, flush=True)
    STATUS.update(voice_claude="working", voice_claude_at=time.time())
    STATUS["sessions"][target] = {"state": "working", "step": "", "at": time.time()}

def notes_file():
    return os.path.expanduser(config().get("NOTES_FILE", "/Users/kush/Githubs/persistent agent/notes/notes.md"))

def save_note(text):
    """Notes mode: append one line per utterance with date and time, instead of sending to Claude."""
    p = notes_file()
    os.makedirs(os.path.dirname(p), exist_ok=True)
    with open(p, "a") as f:
        f.write(time.strftime("%Y-%m-%d %H:%M:%S") + " — " + text.strip() + "\n")
    print("note saved:", text[:80], flush=True)

NOTE_GRACE = 1.5          # seconds the transcript is shown before it's saved (click it to edit instead)
note_lock = threading.Lock()

def propose_note(text):
    """Notes mode: show the transcript first; save after NOTE_GRACE unless the user clicks to edit."""
    with note_lock:
        if STATUS["pending_note"]:                    # a newer note arrived: save the old one now
            finish_note(STATUS["pending_note"]["id"], None, save=True)
        nid = f"{time.time():.3f}"
        STATUS["pending_note"] = {"id": nid, "text": text, "at": time.time(), "held": False}
    def autosave():
        time.sleep(NOTE_GRACE + 0.15)                 # a little slack for the pet's click to arrive
        with note_lock:
            n = STATUS["pending_note"]
            if n and n["id"] == nid and not n["held"]:
                finish_note(nid, None, save=True)
    threading.Thread(target=autosave, daemon=True).start()

def finish_note(nid, text, save):
    """Call with note_lock held."""
    n = STATUS["pending_note"]
    if not n or n["id"] != nid:
        return False
    STATUS["pending_note"] = None
    final = (text if text is not None else n["text"]).strip()
    if save and final:
        save_note(final)
        STATUS["saved_note"] = {"id": nid, "text": final, "at": time.time()}
    return True

_gate_vad = None
_gate_lock = threading.Lock()
NOISE = {"you", "thank you", "thanks", "uh", "um", "hmm", "mm", "ah", "oh", "yeah", "okay", "ok", "bye", "the", "a"}

def speech_seconds(path):
    """How much real speech is in a recording (Silero VAD, the same detector auto mode uses)."""
    global _gate_vad
    import torch, soundfile as sf
    audio, sr = sf.read(path, dtype="float32")
    if audio.ndim > 1: audio = audio[:, 0]
    with _gate_lock:
        if _gate_vad is None:
            from silero_vad import load_silero_vad
            _gate_vad = load_silero_vad()
            keep_resident.pin_weights(_gate_vad)
        _gate_vad.reset_states()
        n, voiced = 512, 0
        for i in range(0, len(audio) - n + 1, n):
            if _gate_vad(torch.from_numpy(audio[i:i + n].copy()), sr).item() > 0.5:
                voiced += 1
    return voiced * n / sr

def is_noise(text):
    t = re.sub(r"[^a-z ]", "", text.lower()).strip()
    return not t or t in NOISE

def deliver(path, as_note=False):
    """Transcribe a recorded utterance and send it to its session — but only if you actually said something:
    silence, a cough or a breath is dropped before anything is sent (so nothing gets started by accident)."""
    try:
        voiced = speech_seconds(path)
    except Exception as e:
        print("speech check failed:", repr(e), flush=True); voiced = 1.0
    if voiced < 0.35:
        print(f"dropped: no speech ({voiced:.2f}s voiced)", flush=True)
        try: os.unlink(path)
        except OSError: pass
        return ""
    STATUS["transcribing"] = True
    try:
        text = transcribe(path)
    finally:
        STATUS["transcribing"] = False
        os.unlink(path)
    if is_noise(text):
        if text: print("dropped: noise transcript:", repr(text), flush=True)
        return ""
    if len(text.split()) >= 1:
        if STATUS["notes"] or as_note:
            propose_note(text)
        else:
            send_to_claude(text)
        STATUS.update(heard=text, heard_at=time.time())
    return text

def mic_device():
    """Prefer the built-in mic: AirPods' mic flips them into low-quality call audio and hears less of the room."""
    want = config().get("VOICE_MIC", "MacBook").lower()
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and want and want in d["name"].lower():
            return i
    return None                                # fall back to the system default

def voice_busy():
    """True while Joe is talking/has queued speech or the voice session is working (notes mode: only Joe talking)."""
    if STATUS["notes"]:
        return STATUS["speaking"] or STATUS["transcribing"]
    working = STATUS["voice_claude"] == "working" and time.time() - STATUS["voice_claude_at"] < 600
    return working or STATUS["speaking"] or not jobs.empty() or STATUS["transcribing"]

def interrupt_claude():
    """Barge-in: silence Joe, drop queued speech, and stop the voice session's current turn (Esc)."""
    global gen
    gen += 1
    abort_all()
    if STATUS["voice_claude"] == "working":
        import subprocess
        subprocess.run(["/opt/homebrew/bin/tmux", "send-keys", "-t", STATUS.get("target") or "voice", "Escape"])
        STATUS.update(voice_claude="idle", voice_claude_at=time.time())
    print("barge-in: interrupted", flush=True)

def auto_listen():
    """Hands-free loop. The mic stays open in auto mode (built-in mic). When it's your turn, speech starts
    an utterance right away. While Joe talks or Claude works, the mic is ignored unless VOICE_BARGE_IN=on,
    in which case sustained louder-than-echo speech interrupts (Joe stops, Claude's turn is cancelled).
    An utterance ends after 0.8 s of silence, then it is transcribed and sent."""
    import tempfile, collections, torch
    import soundfile as sf
    from silero_vad import load_silero_vad
    vad = load_silero_vad()
    keep_resident.pin_weights(vad)
    CH = 512                                   # 32 ms at 16 kHz (Silero's frame size)
    while True:
        if not STATUS["auto"] or STATUS["ptt"] or TASK["recording"]:   # task board recording: your words go there
            time.sleep(0.1); continue
        frames = queue.Queue()
        try:
            stream = sd.InputStream(device=mic_device(), samplerate=16000, channels=1, dtype="float32",
                                    blocksize=CH, callback=lambda d, f, t, st: frames.put(d[:, 0].copy()))
            stream.start()
        except Exception as e:
            print("auto mic error:", e, flush=True)
            if is_audio_error(e): refresh_audio()
            time.sleep(2); continue
        vad.reset_states()
        preroll = collections.deque(maxlen=12)  # ~0.4 s kept so the first word isn't clipped
        speech, talking, silent, voiced, strong = [], False, 0, 0, 0
        echo = 0.0                              # running mic loudness while Joe talks (speaker echo)
        idle_since = None
        empty = 0
        try:
            while STATUS["auto"] and not STATUS["ptt"] and not TASK["recording"]:
                try: d = frames.get(timeout=0.5); empty = 0
                except queue.Empty:
                    empty += 1
                    if empty >= 6: break       # no audio for 3 s: stream died, reopen it
                    continue
                if len(d) != CH: continue
                rms = float(np.sqrt(np.mean(d ** 2)))
                p = vad(torch.from_numpy(d), 16000).item()
                busy = voice_busy()
                if not talking:
                    preroll.append(d)
                    if busy and config().get("VOICE_BARGE_IN", "off") != "on":
                        idle_since = None              # barge-in off: ignore the mic until it's your turn
                        STATUS["listening"] = False
                        preroll.clear()                # don't carry Joe's last words into your utterance
                        continue
                    if busy:
                        idle_since = None
                        STATUS["listening"] = False
                        if STATUS["speaking"]:
                            echo = 0.95 * echo + 0.05 * rms if p < 0.8 else echo
                            ok = p > 0.85 and rms > max(0.01, echo * 2.5)   # louder than Joe's own echo
                            need = 11                                     # ~0.35 s sustained
                        else:
                            ok, need = p > 0.7, 8                         # Claude working quietly: ~0.25 s
                        strong = strong + 1 if ok else 0
                        if strong >= need:
                            interrupt_claude()
                            talking, speech, strong = True, list(preroll), 0
                            STATUS.update(listening=True, heard="")
                    else:
                        idle_since = idle_since or time.time()
                        if time.time() - idle_since < 0.5:   # let the last spoken word die out
                            continue
                        STATUS["listening"] = True
                        STATUS["level"] = 0.0
                        if p > 0.6:
                            talking, speech = True, list(preroll)
                            STATUS["heard"] = ""
                else:
                    speech.append(d)
                    STATUS["level"] = min(1.0, rms * 12)
                    voiced += p > 0.5
                    silent = silent + 1 if p < 0.35 else 0
                    if silent * CH / 16000 >= 0.8 or len(speech) * CH / 16000 > 30:
                        break                  # 0.8 s of silence ends the utterance (30 s cap)
        finally:
            try: stream.stop(); stream.close()
            except Exception: pass
            STATUS.update(listening=False, level=0.0)
        if talking and voiced * CH / 16000 >= 0.3 and STATUS["auto"]:   # ignore coughs and clicks
            f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False, dir="/tmp")
            sf.write(f.name, np.concatenate(speech), 16000)
            deliver(f.name)

PTT = {"down": False}       # set by the pet (POST /ptt) when PTT_SOURCE=pet: any orb's hotkey held

def command_watch():
    """Hold a speak hotkey: stop Joe talking, record mic; release: transcribe and send to that orb's session.
    The pet watches every orb's hotkey and reports it via /ptt; without the pet (PTT_SOURCE=server) this
    falls back to reading left Option itself."""
    global gen
    import ctypes, tempfile
    import soundfile as sf
    q = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
    q.CGEventSourceFlagsState.restype = ctypes.c_uint64
    q.CGEventSourceFlagsState.argtypes = [ctypes.c_int32]
    q.CGEventSourceKeyState.restype = ctypes.c_bool
    q.CGEventSourceKeyState.argtypes = [ctypes.c_int32, ctypes.c_uint16]
    held_since, stream, chunks = None, None, []
    while True:
        WATCH["beat"] = time.time()
        fl = q.CGEventSourceFlagsState(1)
        # left Option only: Option mask + device-dependent left-Alt bit (NX_DEVICELALTKEYMASK 0x20; right is 0x40)
        if config().get("PTT_SOURCE", "pet") == "pet":
            down = PTT["down"]
        else:
            down = bool(fl & 0x00080000) and bool(fl & 0x00000020)
        now = time.time()
        STATUS["ptt"] = held_since is not None
        if down and held_since is None:
            held_since, chunks = now, []
            try:   # start capturing right away so the first word isn't clipped
                def on_audio(d, f, t, st):
                    chunks.append(d.copy())
                    STATUS["level"] = min(1.0, float(np.sqrt(np.mean(d ** 2))) * 12)
                stream = sd.InputStream(device=mic_device(), samplerate=16000, channels=1, dtype="float32",
                                        callback=on_audio)
                stream.start()
            except Exception as e:
                print("mic error:", e, flush=True); stream = None
                if is_audio_error(e): refresh_audio()
        elif down and now - held_since >= 0.35:
            if not STATUS["listening"]:
                gen += 1                   # a real hold: Joe stops and his queue is dropped
                abort_all()
            STATUS["listening"] = True
        elif not down and held_since is not None:
            held = now - held_since
            held_since = None
            STATUS.update(listening=False, level=0.0)
            if stream:
                try: stream.stop(); stream.close()
                except Exception: pass
                stream = None
            cancelled = PTT.pop("cancel", False)
            if cancelled: print("ptt: cancelled (tap or shortcut)", flush=True)
            if held >= 0.6 and chunks and not cancelled:     # quick Option+key presses (special chars, Option+arrows) are ignored
                audio = np.concatenate(chunks)[:, 0]
                f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False, dir="/tmp")
                sf.write(f.name, audio, 16000)
                threading.Thread(target=deliver, args=(f.name, PTT.get("notes", False)), daemon=True).start()
        time.sleep(0.03)

def drain_spool():
    spool = os.path.join(DIR, "spool")
    for name in sorted(os.listdir(spool)) if os.path.isdir(spool) else []:
        path = os.path.join(spool, name)
        try:
            if time.time() - os.path.getmtime(path) < 300:     # older than 5 min is stale; skip it
                jobs.put((gen, open(path).read(), "SAY", ""))
        finally:
            os.unlink(path)

drain_spool()
threading.Thread(target=worker, daemon=True).start()
def warm_stt():
    """Load the speech model once at start, so your first command isn't the slow one."""
    import tempfile, soundfile as sf
    f = tempfile.NamedTemporaryFile(suffix=".wav", delete=False, dir="/tmp")
    sf.write(f.name, np.zeros(16000, dtype=np.float32), 16000)
    t = time.time()
    try: transcribe(f.name)
    finally:
        stt_warm.set()
        try: os.unlink(f.name)
        except OSError: pass
    print(f"stt: warm ({time.time() - t:.1f}s)", flush=True)

stt_warm = threading.Event()

threading.Thread(target=warm_stt, daemon=True).start()

# ---- meetings: right Option double-tap starts/stops; mic only; transcribed with speaker labels ----
MEETINGS = os.path.join(DIR, "meetings")
MEETING = {"on": False, "started": 0, "folder": "", "stop": None}
FINISHING = set()                                # meetings being saved and transcribed right now

ACTIVE = os.path.join(MEETINGS, "active.json")   # the recording in progress (survives a server restart)
REC = os.path.join(DIR, "meeting_rec.py")

def _alive(pid):
    try: os.kill(pid, 0); return True
    except OSError: return False

def meeting_start():
    import subprocess
    if MEETING["on"] or time.time() - MEETING.get("toggled", 0) < 1.5: return
    MEETING["toggled"] = time.time()
    folder = os.path.join(MEETINGS, time.strftime("%Y-%m-%d %H-%M-%S"))
    os.makedirs(folder, exist_ok=True)
    proc = subprocess.Popen([sys.executable, REC, os.path.join(folder, "audio.wav"), config().get("VOICE_MIC", "MacBook")],
                            stdout=open(os.path.join(folder, "recorder.log"), "w"), stderr=subprocess.STDOUT,
                            start_new_session=True)            # its own process group: our restarts don't kill it
    MEETING.update(on=True, started=time.time(), folder=folder, pid=proc.pid, proc=proc)
    LIVE.update(folder=folder, segs=[], offset=WAV_HEADER, final=False, ai=[], ask={"q": "", "a": "", "busy": False})
    json.dump({"pid": proc.pid, "folder": folder, "started": MEETING["started"]}, open(ACTIVE, "w"))
    STATUS.update(meeting=True, meeting_started=MEETING["started"], meeting_folder=folder)
    print("meeting: recording to", folder, "pid", proc.pid, flush=True)

def meeting_stop():
    if not MEETING["on"] or time.time() - MEETING.get("toggled", 0) < 1.5: return
    MEETING["toggled"] = time.time()
    MEETING["on"] = False
    pid, folder = MEETING["pid"], MEETING["folder"]
    STATUS.update(meeting=False, meeting_transcribing=True)
    FINISHING.add(folder)                                # the leftover sweep leaves it to us
    def finish():
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
        for _ in range(100):                              # let it close the file properly
            if not _alive(pid): break
            p = MEETING.get("proc")
            if p: p.poll()
            time.sleep(0.1)
        if _alive(pid):                                   # stuck in the audio system: it would keep the mic open forever
            print("meeting: recorder didn't stop; forcing it", flush=True)
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
        try: os.unlink(ACTIVE)
        except OSError: pass
        wav = os.path.join(folder, "audio.wav")
        subprocess_repair(wav)
        wait_system_audio(folder)
        mix_system(folder)
        print("meeting: saved", wav, flush=True)
        try: meeting_transcribe(folder, wav)
        finally: FINISHING.discard(folder)
    threading.Thread(target=finish, daemon=True).start()

def subprocess_repair(wav):
    import subprocess
    subprocess.run([sys.executable, os.path.join(DIR, "wav_repair.py"), wav], capture_output=True)

# ---- Mac audio: the pet records what the Mac plays into system.wav (same format) next to the mic's audio.wav ----
def _started(folder, name):
    try: return json.load(open(os.path.join(folder, name)))["started"]
    except Exception: return None

def system_offset(folder):
    """Mic sample index of the Mac audio's first sample."""
    s = _started(folder, "system.json")
    m = _started(folder, "mic.json") or MEETING.get("started") or s
    return int(round((s - m) * 16000)) if s else 0

def wait_system_audio(folder, timeout=6):
    """The pet sees the meeting end a moment after us: give it time to close system.wav."""
    if not os.path.exists(os.path.join(folder, "system.json")): return
    end = time.time() + timeout
    while time.time() < end:
        try:
            if json.load(open(os.path.join(folder, "system.json"))).get("ended"): return
        except Exception: pass
        time.sleep(0.2)

def mix_system(folder):
    """Add the Mac audio into audio.wav in place (no extra disk), lined up by start time; then drop it."""
    import numpy as np
    wav, sw = os.path.join(folder, "audio.wav"), os.path.join(folder, "system.wav")
    if not (os.path.isfile(wav) and os.path.isfile(sw)): return
    try:
        off = system_offset(folder)
        n_mic, n_sys = (os.path.getsize(wav) - WAV_HEADER) // 2, (os.path.getsize(sw) - WAV_HEADER) // 2
        if n_mic > 0 and n_sys > 0:
            mic = np.memmap(wav, dtype="<i2", mode="r+", offset=WAV_HEADER, shape=(n_mic,))
            sysd = np.memmap(sw, dtype="<i2", mode="r", offset=WAV_HEADER, shape=(n_sys,))
            step = 16000 * 60
            for j0 in range(max(0, -off), n_sys, step):              # Mac sample j lands on mic sample j + off
                j1 = min(j0 + step, n_sys, n_mic - off)
                if j1 <= j0: break
                a = mic[j0 + off:j1 + off].astype(np.int32) + sysd[j0:j1]
                mic[j0 + off:j1 + off] = np.clip(a, -32768, 32767)
            mic.flush(); del mic, sysd
        print(f"meeting: mixed in Mac audio ({n_sys / 16000:.0f}s)", flush=True)
    except Exception as e:
        print("meeting: Mac audio mix failed:", repr(e), flush=True); return
    for junk in ("system.wav", "system.json", "mic.json"):
        try: os.remove(os.path.join(folder, junk))
        except OSError: pass

def system_slice(folder, m0, n):
    """Mac audio for mic samples [m0, m0+n), zeros where there's none (yet)."""
    import numpy as np
    out = np.zeros(n, dtype=np.int32)
    sw = os.path.join(folder, "system.wav")
    if not os.path.isfile(sw): return out
    j0 = m0 - system_offset(folder)
    a, b = max(j0, 0), j0 + n
    try:
        with open(sw, "rb") as f:
            f.seek(WAV_HEADER + 2 * a); raw = f.read(2 * max(0, b - a))
    except OSError:
        return out
    x = np.frombuffer(raw[:len(raw) - len(raw) % 2], dtype="<i2")
    out[a - j0:a - j0 + len(x)] = x
    return out

def meeting_recover():
    """After a restart: pick a recording that's still going back up, or finish one whose recorder died;
    and transcribe any meeting that has audio but no transcript yet."""
    try: a = json.load(open(ACTIVE))
    except Exception: a = None
    if a and _alive(a["pid"]):
        MEETING.update(on=True, started=a["started"], folder=a["folder"], pid=a["pid"], proc=None)
        STATUS.update(meeting=True, meeting_started=a["started"], meeting_folder=a["folder"])
        print("meeting: still recording", a["folder"], flush=True)
        live_load(a["folder"])
    elif a:
        try: os.unlink(ACTIVE)
        except OSError: pass
    # any other recorder left from an earlier meeting would keep the mic open: end it
    import subprocess
    keep = MEETING.get("pid") if MEETING["on"] else None
    for line in subprocess.run(["pgrep", "-f", REC], capture_output=True, text=True).stdout.split():
        pid = int(line)
        if pid != keep and pid != os.getpid():
            print("meeting: ending a leftover recorder", pid, flush=True)
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
    stt_warm.wait(180)                                # your first voice command isn't stuck behind a meeting
    for d in sorted(os.listdir(MEETINGS)) if os.path.isdir(MEETINGS) else []:
        f = os.path.join(MEETINGS, d)
        wav = os.path.join(f, "audio.wav")
        if (MEETING["on"] and f == MEETING["folder"]) or f in FINISHING: continue
        if os.path.isfile(wav) and not os.path.exists(os.path.join(f, "transcript.txt")) and os.path.getsize(wav) > 32000:
            subprocess_repair(wav)
            mix_system(f)
            print("meeting: transcribing leftover", f, flush=True)
            meeting_transcribe(f, wav)

MEETING_DB = os.path.join(DIR, "meetings.db")   # its own: never shares a lock with voice commands
meeting_lock = threading.Lock()                  # one meeting transcribed at a time

def meeting_transcribe(folder, wav):
    """One speaker-labelled pass; writes transcript.txt (readable), transcript.srt and transcript.json."""
    import subprocess
    STATUS["meeting_transcribing"] = True
    t = time.time()
    try:
        with meeting_lock:
            out = subprocess.run(["nice", "-n", "15", STT_CLI, "transcribe", wav, "--format", "json", "--speaker-detection", "on",
                                  "--engine", "parakeet", "--no-history", "--database", MEETING_DB],
                                 capture_output=True, text=True, timeout=3 * 3600).stdout
        d = json.loads(out)
        if d.get("ok") is False:                         # e.g. disk full: keep the audio, retry on next start
            raise RuntimeError(d.get("error", "transcription failed")[:300])
        open(os.path.join(folder, "transcript.json"), "w").write(out)
        segs = d.get("transcriptSegments") or []
        def ts(ms, srt=False):
            s, ms = divmod(int(ms), 1000); h, s = divmod(s, 3600); m, s = divmod(s, 60)
            return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}" if srt else (f"{h}:{m:02d}:{s:02d}" if h else f"{m:02d}:{s:02d}")
        started = os.path.basename(folder)
        lines = [f"Meeting {started}", f"{d.get('speakerCount', 0)} speaker(s) · {ts(d.get('durationMs', 0))} long", ""]
        last = None
        for g in segs:                                   # a new paragraph whenever the speaker changes
            who = g.get("speakerLabel") or "Speaker"
            if who != last: lines += ["", f"[{ts(g.get('startMs', 0))}] {who}:"]; last = who
            lines.append(g.get("text", "").strip())
        if not segs: lines.append(d.get("rawTranscript", "").strip() or "(no speech found)")
        open(os.path.join(folder, "transcript.txt"), "w").write("\n".join(lines).strip() + "\n")
        srt = []
        for i, g in enumerate(segs, 1):
            srt += [str(i), f"{ts(g.get('startMs', 0), True)} --> {ts(g.get('endMs', 0), True)}",
                    f"{g.get('speakerLabel', '')}: {g.get('text', '').strip()}", ""]
        open(os.path.join(folder, "transcript.srt"), "w").write("\n".join(srt))
        print(f"meeting: transcribed in {time.time() - t:.0f}s ->", folder, flush=True)
        for junk in (wav, os.path.join(folder, "recorder.log")):   # transcript saved: the audio isn't kept
            try: os.remove(junk)
            except OSError: pass
        if LIVE["folder"] == folder:                    # the board switches to the final transcript
            LIVE.update(segs=[{"start": g.get("startMs", 0), "end": g.get("endMs", 0), "speaker": g.get("speakerLabel") or "Speaker",
                               "text": g.get("text", "").strip()} for g in segs], final=True)
        if LIVE["folder"] == folder and LIVE["ai"]:          # keep what the prompt said, next to the transcript
            open(os.path.join(folder, "prompt-replies.txt"), "w").write("\n\n".join(
                f"[{_ts(x['at'])}] {x['speaker']}: {x['said']}\n  → {x['reply']}" for x in LIVE["ai"]) + "\n")
            json.dump(LIVE["ai"], open(os.path.join(folder, "prompt-replies.json"), "w"))   # so the board can show them again
        try: os.remove(os.path.join(folder, "live.json"))
        except OSError: pass
        STATUS.update(meeting_done=folder, meeting_done_at=time.time())
    except Exception as e:
        print("meeting: transcription failed:", repr(e), flush=True)
    finally:
        STATUS["meeting_transcribing"] = False

# ---- meeting board: live transcription while recording (only while the board is on) ----
WAV_HEADER = 44                                  # meeting_rec.py: 16 kHz mono 16-bit, samples after 44 bytes
LIVE = {"seen": 0, "folder": "", "segs": [], "offset": WAV_HEADER, "final": False,
        "prompt": "", "ai": [], "ask": {"q": "", "a": "", "busy": False}}
LIVE_DB = os.path.join(DIR, "meetings-live.db")
LIVE_EVERY = 15                                  # seconds of new audio per pass

def live_load(folder):
    LIVE.update(folder=folder, segs=[], offset=WAV_HEADER, final=False, ai=[], ask={"q": "", "a": "", "busy": False})
    try:
        d = json.load(open(os.path.join(folder, "live.json")))
        LIVE.update(segs=d.get("segs", []), offset=d.get("offset", WAV_HEADER), ai=d.get("ai", []))
    except Exception:
        pass

def prompt_replies_txt(path):
    """Older meetings kept the replies only as text: "[mm:ss] Speaker N: said" then "  → reply"."""
    out = []
    try: blocks = open(path).read().strip().split("\n\n")
    except OSError: return out
    for b in blocks:
        m = re.match(r"\[(?:(\d+):)?(\d+):(\d+)\] ([^:]+): (.*?)\n  → (.*)", b, re.S)
        if not m: continue
        h, mi, se = int(m.group(1) or 0), int(m.group(2)), int(m.group(3))
        out.append({"at": ((h * 60 + mi) * 60 + se) * 1000 + 1, "speaker": m.group(4), "said": m.group(5).strip(),
                    "reply": m.group(6).strip(), "prompt": ""})
    return out

def meeting_open(folder):
    """Put a finished meeting back on the board: its transcript, the prompt's replies, and Ask works on it."""
    folder = os.path.realpath(folder)
    if MEETING["on"] or not folder.startswith(os.path.realpath(MEETINGS) + os.sep): return False
    try: d = json.load(open(os.path.join(folder, "transcript.json")))
    except Exception: return False
    try: ai = json.load(open(os.path.join(folder, "prompt-replies.json")))
    except Exception: ai = prompt_replies_txt(os.path.join(folder, "prompt-replies.txt"))
    LIVE.update(folder=folder, final=True, ai=ai, ask={"q": "", "a": "", "busy": False},
                segs=[{"start": g.get("startMs", 0), "end": g.get("endMs", 0), "speaker": g.get("speakerLabel") or "Speaker",
                       "text": g.get("text", "").strip()} for g in d.get("transcriptSegments") or []])
    return True

def meeting_live_view():
    return {"recording": MEETING["on"], "started": MEETING.get("started", 0),
            "transcribing": STATUS.get("meeting_transcribing", False), "final": LIVE["final"],
            "folder": LIVE["folder"], "segments": LIVE["segs"], "prompt": LIVE["prompt"], "ai": LIVE["ai"], "ask": LIVE["ask"]}

def live_pass(folder):
    """Transcribe the audio recorded since the last pass, cut at the quietest moment of its last 3 s
    (so words aren't split), and add its lines with timestamps from the meeting's start."""
    import subprocess, numpy as np, soundfile as sf
    wav = os.path.join(folder, "audio.wav")
    try: size = os.path.getsize(wav)
    except OSError: return
    end = size - (size - WAV_HEADER) % 2
    if end - LIVE["offset"] < 8 * 32000: return              # wait for at least 8 s of new audio
    with open(wav, "rb") as f:
        f.seek(LIVE["offset"]); raw = f.read(end - LIVE["offset"])
    x = np.frombuffer(raw, dtype="<i2").astype(np.int32)
    x = np.clip(x + system_slice(folder, (LIVE["offset"] - WAV_HEADER) // 2, len(x)), -32768, 32767).astype(np.int16)
    final_chunk = not MEETING["on"]
    cut = len(x)
    if not final_chunk and len(x) > 4 * 16000:
        tail = x[-3 * 16000:].astype(np.float32)
        win = 1600                                              # 0.1 s windows
        e = [float(np.mean(tail[i:i + win] ** 2)) for i in range(0, len(tail) - win, win)]
        cut = len(x) - 3 * 16000 + int(np.argmin(e)) * win + win // 2
    x = x[:cut]
    t0 = (LIVE["offset"] - WAV_HEADER) // 32                     # ms into the meeting
    chunk = os.path.join(folder, "live-chunk.wav")
    try:
        sf.write(chunk, x, 16000, subtype="PCM_16")
        out = subprocess.run(["nice", "-n", "10", STT_CLI, "transcribe", chunk, "--format", "json", "--speaker-detection", "on",
                              "--engine", "parakeet", "--no-history", "--database", LIVE_DB],
                             capture_output=True, text=True, timeout=300).stdout
        d = json.loads(out or "{}")
    except Exception as e:
        print("meeting board: pass failed:", repr(e), flush=True); return
    finally:
        try: os.remove(chunk)
        except OSError: pass
    if d.get("ok") is False:
        print("meeting board: pass failed:", d.get("error", "")[:200], flush=True); return
    if LIVE["folder"] != folder or LIVE["final"]: return         # a newer meeting, or the final transcript won
    segs = d.get("transcriptSegments") or []
    if not segs and (d.get("rawTranscript") or "").strip():
        segs = [{"startMs": 0, "endMs": len(x) // 16, "text": d["rawTranscript"]}]
    new = []
    for g in segs:
        t = (g.get("text") or "").strip()
        if t:
            new.append({"start": t0 + g.get("startMs", 0), "end": t0 + g.get("endMs", 0),
                        "speaker": g.get("speakerLabel") or "Speaker", "text": t})
    LIVE["segs"] += new
    LIVE["offset"] += cut * 2
    live_save(folder)
    apply_prompt(new)

def live_save(folder):
    try: json.dump({"segs": LIVE["segs"], "offset": LIVE["offset"], "ai": LIVE["ai"]}, open(os.path.join(folder, "live.json"), "w"))
    except OSError: pass

def _ts(ms):
    s = int(ms // 1000); h = s // 3600
    return f"{h}:{s // 60 % 60:02d}:{s % 60:02d}" if h else f"{s // 60:02d}:{s % 60:02d}"

def transcript_lines(segs, upto=None):
    """[mm:ss] Speaker N: text — one line per turn, so the model knows who said what and when."""
    out, last = [], None
    for g in segs:
        if upto is not None and g["start"] > upto: break
        if last and last[0] == g["speaker"]: last[1].append(g["text"]); continue
        last = (g["speaker"], [g["text"]], g["start"]); out.append(last)
    return [f"[{_ts(st)}] {who}: {' '.join(t)}" for who, t, st in out]

OPENROUTER_MODEL = "inception/mercury-3"

def openrouter(messages, max_tokens=4000):
    """One reply from Mercury on OpenRouter. The key is read from your .env (never stored here)."""
    import urllib.request
    env = os.path.expanduser(config().get("OPENROUTER_ENV", "/Users/kush/Githubs/.env"))
    key = next((l.split("=", 1)[1].strip().strip('"\'') for l in open(env) if l.startswith("OPENROUTER_API_KEY=")), "")
    if not key: raise RuntimeError("no OPENROUTER_API_KEY in " + env)
    req = urllib.request.Request("https://openrouter.ai/api/v1/chat/completions", method="POST",
        data=json.dumps({"model": config().get("MEETING_MODEL", OPENROUTER_MODEL), "messages": messages,
                         "max_tokens": max_tokens}).encode(),
        headers={"Authorization": "Bearer " + key, "Content-Type": "application/json", "X-Title": "VoicePet meeting board"})
    d = json.loads(urllib.request.urlopen(req, timeout=90).read())
    if d.get("error"): raise RuntimeError(str(d["error"])[:200])
    out = (d["choices"][0]["message"].get("content") or "").strip()
    if not out and max_tokens < 12000:             # it spent the whole budget thinking: once more with 3x room
        print("openrouter: empty reply after", (d.get("usage") or {}).get("completion_tokens"), "tokens; retrying", flush=True)
        return openrouter(messages, max_tokens * 3)
    return out

ai_pool = None

def apply_prompt(new):
    """Run the board's prompt on each new turn (consecutive lines from one speaker), with the speaker and
    time, plus the last few turns for context. Replies land on the board under what they answer."""
    global ai_pool
    prompt, folder = LIVE["prompt"].strip(), LIVE["folder"]
    if not prompt or not new: return
    if ai_pool is None:
        from concurrent.futures import ThreadPoolExecutor
        ai_pool = ThreadPoolExecutor(3)
    turns = []
    for g in new:
        if turns and turns[-1]["speaker"] == g["speaker"]: turns[-1]["text"] += " " + g["text"]
        else: turns.append(dict(g))
    for t in turns:
        if len(t["text"].split()) < 3: continue                 # "Yeah." / "Okay." aren't worth a reply
        context = transcript_lines(LIVE["segs"], upto=t["start"])[-8:-1]
        def run(t=t, context=context):
            try:
                reply = openrouter([
                    {"role": "system", "content": "You help during a live meeting. The user's instruction is applied to one "
                        "thing a single speaker just said. Speakers are labelled Speaker 1, Speaker 2, ... (from automatic "
                        "speaker detection) with [mm:ss] times. Answer the instruction for that line only, briefly "
                        "(1-3 sentences), plain text, no preamble. If the instruction doesn't apply to it, reply with just: -"
                        "\n\nInstruction: " + prompt},
                    {"role": "user", "content": ("Earlier:\n" + "\n".join(context) + "\n\n" if context else "")
                        + f"Just said:\n[{_ts(t['start'])}] {t['speaker']}: {t['text']}"}])
            except Exception as e:
                print("meeting board: prompt failed:", repr(e)[:200], flush=True); return
            if reply and reply != "-" and LIVE["folder"] == folder:
                LIVE["ai"].append({"at": t["start"], "speaker": t["speaker"], "said": t["text"], "reply": reply, "prompt": prompt})
                LIVE["ai"].sort(key=lambda a: a["at"])
                live_save(folder)
        ai_pool.submit(run)

def meeting_ask(q):
    """One question about the meeting so far (the whole transcript, with speakers and times); one answer."""
    lines = transcript_lines(LIVE["segs"])
    LIVE["ask"] = {"q": q, "a": "", "busy": True}
    try:
        a = openrouter([
            {"role": "system", "content": "You answer questions about a meeting from its transcript. Each line is "
                "[mm:ss] Speaker N: what they said (speaker numbers come from automatic speaker detection; the user may be "
                "one of them). Refer to people by their speaker number and time when it helps. Be concise and plain text. "
                "If the transcript doesn't say, say so."},
            {"role": "user", "content": "Transcript so far:\n" + ("\n".join(lines) or "(nothing transcribed yet)")
                + "\n\nQuestion: " + q}])
    except Exception as e:
        a = "Couldn't get an answer: " + str(e)[:150]
    LIVE["ask"] = {"q": q, "a": a, "busy": False}
    return a

def meeting_live():
    stt_warm.wait(180)
    while True:
        time.sleep(LIVE_EVERY)
        if time.time() - LIVE["seen"] < 10 and MEETING["on"] and LIVE["folder"] == MEETING["folder"] and not LIVE["final"]:
            live_pass(LIVE["folder"])

# ---- Task boards: say a list (or anything), see it written down, then have Mercury reshape it.
# Several cards can be on screen; each is its own board. One records at a time (there's one mic).
TASKS = os.path.join(DIR, "tasks")
CARDS_FILE = os.path.join(TASKS, "cards.json")       # every card (survives restarts)
TASK = {"recording": False, "started": 0, "pid": None, "folder": "", "card": "", "live": "", "transcribing": False}
CARDS = []                                            # [{id, original, ai, prompt, busy, hidden}], oldest first

def card(cid):
    return next((c for c in CARDS if c["id"] == cid), None)

def task_view():
    rec = {k: TASK[k] for k in ("recording", "started", "live", "transcribing", "card")}
    rec["level_file"] = os.path.join(TASK["folder"], "level") if TASK["recording"] else ""   # the pet reads it for the wave
    rec["ready"] = TASK["recording"] and os.path.exists(os.path.join(TASK["folder"], "mic.json"))   # the mic is really on
    return {"rec": rec, "cards": CARDS}

def task_save():
    os.makedirs(TASKS, exist_ok=True)
    json.dump([{k: c[k] for k in ("id", "original", "ai", "prompt", "hidden")} for c in CARDS], open(CARDS_FILE, "w"), indent=1)

def task_load():
    try:
        CARDS[:] = [dict(c, busy=False) for c in json.load(open(CARDS_FILE))]
    except Exception:
        old = os.path.join(TASKS, "current.json")      # the single board from before
        try:
            c = json.load(open(old))
            if c.get("original") or c.get("ai"): CARDS.append(card_new(c.get("original", ""), c.get("ai", ""), c.get("prompt", ""), save=False))
            os.rename(old, old + ".bak")
        except Exception:
            pass
        task_save()
    saved = os.path.join(TASKS, "saved")             # cards set aside by the old single board's +: back as boards
    for f in sorted(os.listdir(saved)) if os.path.isdir(saved) else []:
        if not f.endswith(".json"): continue          # already brought back once
        try:
            c = json.load(open(os.path.join(saved, f)))
            CARDS.insert(0, card_new(c.get("original", ""), c.get("ai", ""), c.get("prompt", ""), save=False))
            os.rename(os.path.join(saved, f), os.path.join(saved, f + ".imported"))
        except Exception:
            pass
    task_save()

def card_new(original="", ai="", prompt="", save=True):
    c = {"id": time.strftime("%Y%m%d-%H%M%S-") + os.urandom(2).hex(), "original": original, "ai": ai,
         "prompt": prompt, "busy": False, "hidden": False}
    if save: CARDS.append(c); task_save()
    return c

def card_delete(cid):
    c = card(cid)
    if not c or (TASK["card"] == cid and (TASK["recording"] or TASK["transcribing"])): return
    CARDS.remove(c)
    if c["original"].strip() or c["ai"].strip():       # a copy, just in case
        d = os.path.join(TASKS, "deleted"); os.makedirs(d, exist_ok=True)
        json.dump(c, open(os.path.join(d, cid + ".json"), "w"), indent=1)
    task_save()

def task_start(cid="", new=False):
    import subprocess
    if TASK["recording"]: return
    for _ in range(100):                        # the last one is still being written down: queue behind it
        if not TASK["transcribing"]: break
        time.sleep(0.1)
    c = card_new() if new or not card(cid) else card(cid)
    c["hidden"] = False
    folder = os.path.join(TASKS, time.strftime("%Y-%m-%d %H-%M-%S"))
    os.makedirs(folder, exist_ok=True)
    proc = subprocess.Popen([sys.executable, REC, os.path.join(folder, "audio.wav"), config().get("VOICE_MIC", "MacBook"),
                             os.path.join(folder, "level")],
                            stdout=open(os.path.join(folder, "recorder.log"), "w"), stderr=subprocess.STDOUT,
                            start_new_session=True)
    TASK.update(recording=True, started=time.time(), pid=proc.pid, folder=folder, card=c["id"], live="", proc=proc)
    threading.Thread(target=task_live, args=(folder,), daemon=True).start()
    print("task board: recording to", folder, "for card", c["id"], flush=True)

def task_snapshot(folder):
    """What's been said so far: a copy of the recording with its header fixed, transcribed."""
    import shutil
    wav, snap = os.path.join(folder, "audio.wav"), os.path.join(folder, "snap.wav")
    try: shutil.copyfile(wav, snap)
    except OSError: return ""
    subprocess_repair(snap)
    try: return transcribe(snap)
    finally:
        try: os.unlink(snap)
        except OSError: pass

def task_live(folder):
    """While recording: re-read the recording every few seconds so your words show up as you say them."""
    while TASK["recording"] and TASK["folder"] == folder:
        time.sleep(4)
        if not TASK["recording"]: break
        t = task_snapshot(folder)
        if TASK["recording"] and TASK["folder"] == folder and t: TASK["live"] = t

def task_stop():
    if not TASK["recording"]: return
    pid, folder, cid = TASK["pid"], TASK["folder"], TASK["card"]
    TASK.update(recording=False, transcribing=True)
    def finish():
        try: os.kill(pid, signal.SIGTERM)
        except OSError: pass
        for _ in range(100):
            if not _alive(pid): break
            p = TASK.get("proc")
            if p: p.poll()
            time.sleep(0.1)
        if _alive(pid):
            try: os.kill(pid, signal.SIGKILL)
            except OSError: pass
        wav = os.path.join(folder, "audio.wav")
        subprocess_repair(wav)
        try:
            text = transcribe(wav)
        finally:
            TASK.update(transcribing=False, live="")
        c = card(cid)
        if text and c:                              # a second recording on a card adds to it
            c["original"] = (c["original"].rstrip() + "\n\n" + text).strip() if c["original"] else text
            open(os.path.join(folder, "original.txt"), "w").write(text)
            try: os.unlink(wav)                     # the words are kept; the audio isn't needed
            except OSError: pass
        else:                                       # nothing said: leave nothing behind
            import shutil; shutil.rmtree(folder, ignore_errors=True)
        task_save()
        print("task board: transcribed", len(text), "chars", flush=True)
    threading.Thread(target=finish, daemon=True).start()

def task_ask(cid, prompt):
    """Reshape what you said, with your instruction. Always from your original words, never from the last result."""
    c = card(cid)
    if not c or not c["original"].strip() or not prompt or c["busy"]: return
    c.update(busy=True, prompt=prompt)
    def run():
        try:
            out = openrouter([
                {"role": "system", "content": "The user spoke some text out loud (often a list of tasks); it was transcribed "
                    "automatically, so fix obvious transcription slips. Rewrite it following the user's instruction. Keep "
                    "every item they said unless told otherwise; don't invent new ones. Format it however you think "
                    "reads best. Output only the result, no preamble."},
                {"role": "user", "content": "What I said:\n" + c["original"] + "\n\nInstruction: " + prompt}])
            if not out: out = "Mercury came back empty. Try the prompt again."
        except Exception as e:
            out = "Couldn't reach Mercury: " + str(e)[:150]
        c.update(ai=out, busy=False)
        task_save()
    threading.Thread(target=run, daemon=True).start()

def task_post(path, ev):
    """POST /task/<action> {"id", "text", "original", "ai"}"""
    act, cid, v = path.rsplit("/", 1)[-1], ev.get("id") or "", (ev.get("text") or "").strip()
    c = card(cid)
    if act == "record":                          # "start" (this card) / "new" (hold `: a fresh card) / "stop"
        if v == "stop" or (v not in ("start", "new") and TASK["recording"]): task_stop()
        else: task_start(cid, new=v == "new")
    elif act == "new": card_new()                # the + button
    elif act == "ask": task_ask(cid, v)
    elif act == "delete": card_delete(cid)
    elif act == "hide" and c: c["hidden"] = True; task_save()
    elif act == "showall":                        # the pet's menu: every card back on screen
        for x in CARDS: x["hidden"] = False
        if not CARDS: card_new()
        task_save()
    elif act == "edit" and c:
        for k in ("original", "ai"):
            if isinstance(ev.get(k), str): c[k] = ev[k].strip()
        task_save()

task_load()

WATCH = {"beat": time.time()}

def watchdog():
    """The recorder can get stuck inside the audio system (e.g. after a Gemini audio stall). If it stops
    ticking, restart the whole server (launchd brings it straight back) so the mic works again."""
    while True:
        time.sleep(3)
        stuck = time.time() - WATCH["beat"]
        if stuck > 10:
            print(f"watchdog: recorder stuck for {stuck:.0f}s; restarting the voice server", flush=True)
            os._exit(1)

threading.Thread(target=command_watch, daemon=True).start()
threading.Thread(target=watchdog, daemon=True).start()
threading.Thread(target=meeting_recover, daemon=True).start()
threading.Thread(target=meeting_live, daemon=True).start()
threading.Thread(target=auto_listen, daemon=True).start()
print("kitten server ready on", PORT, MODEL_NAME, flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
