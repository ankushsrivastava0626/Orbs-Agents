#!/usr/bin/env python3
"""Record the mic to a WAV until told to stop (SIGTERM/SIGINT). Its own process, so a restart of the
voice server never cuts a meeting off. usage: meeting_rec.py <out.wav> [device-name-part]"""
import signal, sys, threading
import sounddevice as sd, soundfile as sf

out, want = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "MacBook").lower()
stop = threading.Event()
for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(s, lambda *_: stop.set())
dev = next((i for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0 and want in d["name"].lower()), None)
with sf.SoundFile(out, "w", samplerate=16000, channels=1, subtype="PCM_16") as f:
    lock = threading.Lock()
    def cb(d, frames, t, st):
        with lock: f.write(d.copy())
    with sd.InputStream(device=dev, samplerate=16000, channels=1, dtype="float32", callback=cb):
        n = 0
        while not stop.wait(1):
            n += 1
            if n % 5 == 0:
                with lock: f.flush()                       # every 5 s: a crash loses little, and the live board can read it
print("saved", out, flush=True)
