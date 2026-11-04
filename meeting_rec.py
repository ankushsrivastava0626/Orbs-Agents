#!/usr/bin/env python3
"""Record the mic to a WAV until told to stop (SIGTERM/SIGINT). Its own process, so a restart of the
voice server never cuts a meeting off. usage: meeting_rec.py <out.wav> [device-name-part]"""
import os, signal, sys, threading, time
import sounddevice as sd, soundfile as sf

out, want = sys.argv[1], (sys.argv[2] if len(sys.argv) > 2 else "MacBook").lower()
stop = threading.Event()
for s in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP): signal.signal(s, lambda *_: stop.set())
dev = next((i for i, d in enumerate(sd.query_devices()) if d["max_input_channels"] > 0 and want in d["name"].lower()), None)
with sf.SoundFile(out, "w", samplerate=16000, channels=1, subtype="PCM_16") as f:
    lock = threading.Lock()
    level = sys.argv[3] if len(sys.argv) > 3 else ""      # optional: how loud right now, for the task board's wave
    last = [0.0]
    def cb(d, frames, t, st):
        with lock: f.write(d.copy())
        if level and time.time() - last[0] > 0.04:
            last[0] = time.time()
            try:
                with open(level + ".tmp", "w") as lf: lf.write("%.4f" % float((d ** 2).mean() ** 0.5))
                os.replace(level + ".tmp", level)
            except OSError: pass
    with sd.InputStream(device=dev, samplerate=16000, channels=1, dtype="float32", callback=cb):
        import json, os, time                              # when the mic really started: Mac audio is lined up to it
        json.dump({"started": time.time()}, open(os.path.join(os.path.dirname(out), "mic.json"), "w"))
        n = 0
        while not stop.wait(1):
            n += 1
            if n % 5 == 0:
                with lock: f.flush()                       # every 5 s: a crash loses little, and the live board can read it
        # Stopping: everything is on disk first, then closing the mic. If macOS's audio system hangs on that
        # close (it can, after a device change), leave anyway: nothing is lost, the server fixes the header.
        with lock: f.flush()
        import os
        threading.Thread(target=lambda: (time.sleep(3), os._exit(0)), daemon=True).start()
print("saved", out, flush=True)
