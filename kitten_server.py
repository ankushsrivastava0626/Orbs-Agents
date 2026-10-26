"""Local KittenTTS speech server: keeps the model loaded and owns the speech queue.

POST /say   body=text  -> queued, spoken in order (sentence-pipelined)
POST /stop             -> stop now and drop everything queued
GET  /health
"""
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

from kittenml import KittenTTS
MODEL_NAME = config().get("KITTEN_MODEL", "KittenML/kitten-tts-nano-0.8-int8")
model = KittenTTS(MODEL_NAME)

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

os.environ.setdefault("HF_HUB_OFFLINE", "1")   # Kokoro weights + af_heart are already in the HF cache
from kokoro import KPipeline
from gemini_voice import Player
import gemini_voice
gemini_voice.LEVEL_CB = lambda v: STATUS.__setitem__("out_level", v)
kokoro_pipes = {"a": KPipeline(lang_code="a", repo_id="hexgrad/Kokoro-82M")}

def kokoro_pipe(voice):
    """Voice prefix picks the accent: a* American, b* British. Pipelines share one model."""
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

def worker():
    while True:
        my_gen, text, kind, who = jobs.get()
        try: follow_output_device()
        except Exception as e: print("output check failed:", repr(e), flush=True)
        STATUS["speaking_session"] = who
        if kind == "SAY":                                     # remember each orb's last reply (hover shows it)
            STATUS["last_said"][who or "voice"] = {"id": f"s{time.time():.3f}", "session": who or "voice",
                                                   "text": text, "at": time.time()}
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
            self._ok(json.dumps(STATUS).encode())
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
    CH = 512                                   # 32 ms at 16 kHz (Silero's frame size)
    while True:
        if not STATUS["auto"] or STATUS["ptt"]:
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
            while STATUS["auto"] and not STATUS["ptt"]:
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
    t = time.time(); transcribe(f.name)
    try: os.unlink(f.name)
    except OSError: pass
    print(f"stt: warm ({time.time() - t:.1f}s)", flush=True)

threading.Thread(target=warm_stt, daemon=True).start()

# ---- meetings: right Option double-tap starts/stops; mic only; transcribed with speaker labels ----
MEETINGS = os.path.join(DIR, "meetings")
MEETING = {"on": False, "started": 0, "folder": "", "stop": None}

def meeting_start():
    import soundfile as sf
    if MEETING["on"]: return
    folder = os.path.join(MEETINGS, time.strftime("%Y-%m-%d %H-%M-%S"))
    os.makedirs(folder, exist_ok=True)
    stop = threading.Event()
    MEETING.update(on=True, started=time.time(), folder=folder, stop=stop)
    STATUS.update(meeting=True, meeting_started=MEETING["started"], meeting_folder=folder)
    def rec():
        wav = os.path.join(folder, "audio.wav")
        try:
            with sf.SoundFile(wav, "w", samplerate=16000, channels=1, subtype="PCM_16") as f:
                def cb(d, frames, t, st): f.write(d.copy())
                with sd.InputStream(device=mic_device(), samplerate=16000, channels=1, dtype="float32", callback=cb):
                    while not stop.wait(0.5): pass
        except Exception as e:
            print("meeting: recording failed:", repr(e), flush=True)
        print("meeting: saved", wav, flush=True)
        meeting_transcribe(folder, wav)
    threading.Thread(target=rec, daemon=True).start()
    STATUS["meeting_transcribing"] = False
    print("meeting: recording to", folder, flush=True)

def meeting_stop():
    if not MEETING["on"]: return
    MEETING["on"] = False
    MEETING["stop"].set()
    STATUS.update(meeting=False, meeting_transcribing=True)

MEETING_DB = os.path.join(DIR, "meetings.db")   # its own: never shares a lock with voice commands
meeting_lock = threading.Lock()                  # one meeting transcribed at a time

def meeting_transcribe(folder, wav):
    """One speaker-labelled pass; writes transcript.txt (readable), transcript.srt and transcript.json."""
    import subprocess
    STATUS["meeting_transcribing"] = True
    t = time.time()
    try:
        with meeting_lock:
            out = subprocess.run([STT_CLI, "transcribe", wav, "--format", "json", "--speaker-detection", "on",
                                  "--engine", "parakeet", "--no-history", "--database", MEETING_DB],
                                 capture_output=True, text=True, timeout=3 * 3600).stdout
        open(os.path.join(folder, "transcript.json"), "w").write(out)
        d = json.loads(out)
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
        STATUS.update(meeting_done=folder, meeting_done_at=time.time())
    except Exception as e:
        print("meeting: transcription failed:", repr(e), flush=True)
    finally:
        STATUS["meeting_transcribing"] = False

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
threading.Thread(target=auto_listen, daemon=True).start()
print("kitten server ready on", PORT, MODEL_NAME, flush=True)
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
