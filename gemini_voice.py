"""Gemini Live as the speaking voice ("Joe"): text in, persona-voiced audio out. No mic, no video."""
import asyncio, subprocess, threading, time
import numpy as np
from audiotsm import wsola
from audiotsm.io.array import ArrayReader, ArrayWriter
import sounddevice as sd
from google import genai
from google.genai import types

KEYCHAIN_SERVICES = ["GEMINI_API_KEY", "echo-realtime-google-api-key"]   # first one found is used

def api_key():
    for svc in KEYCHAIN_SERVICES:
        try:
            k = subprocess.run(["security", "find-generic-password", "-s", svc, "-w"],
                               capture_output=True, text=True, timeout=5).stdout.strip()
        except Exception:
            k = ""
        if k:
            return k
    return ""

class GeminiVoice:
    def __init__(self, persona_path, on_said):
        self.persona_path = persona_path
        self.on_said = on_said            # callback(text) with Joe's live transcript, for the pet
        self.loop = asyncio.new_event_loop()
        threading.Thread(target=self.loop.run_forever, daemon=True).start()
        self.session, self.cm, self.opened_at, self.key_used = None, None, 0, ""
        self.stream = None
        self.last_error = None

    def available(self):
        return bool(api_key())

    def abort(self):                      # called on hotkey hold / mute
        p = self.stream
        if p: p.stop()

    def speak(self, text, kind, still_current, model, voice, speed=1.0):
        fut = asyncio.run_coroutine_threadsafe(self._speak(text, kind, still_current, model, voice, speed), self.loop)
        return fut.result(timeout=180)

    async def _connect(self, model, voice):
        await self._close()
        key = api_key()
        client = genai.Client(http_options={"api_version": "v1beta"}, api_key=key)
        config = types.LiveConnectConfig(
            response_modalities=["AUDIO"],
            output_audio_transcription=types.AudioTranscriptionConfig(),
            speech_config=types.SpeechConfig(voice_config=types.VoiceConfig(
                prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice))),
            context_window_compression=types.ContextWindowCompressionConfig(
                trigger_tokens=104857, sliding_window=types.SlidingWindow(target_tokens=52428)),
            system_instruction=types.Content(parts=[types.Part(text=open(self.persona_path).read())], role="user"),
        )
        self.cm = client.aio.live.connect(model=model, config=config)
        self.session = await self.cm.__aenter__()
        self.opened_at, self.key_used = time.time(), key

    async def _close(self):
        if self.cm:
            try: await self.cm.__aexit__(None, None, None)
            except Exception: pass
        self.session, self.cm = None, None

    async def _speak(self, text, kind, still_current, model, voice, speed=1.0):
        for attempt in (1, 2):            # one reconnect on a dropped/expired session
            try:
                if not self.session or time.time() - self.opened_at > 540:   # Live sessions are time-limited
                    await self._connect(model, voice)
                await self.session.send_client_content(
                    turns=types.Content(role="user", parts=[types.Part(text=(
                        f"SAY (speak exactly this, nothing before or after):\n{text}" if kind == "SAY" else f"{kind}:\n{text}"))]),
                    turn_complete=True)
                said = ""
                # Gemini has no speaking-rate setting: speed up playback, pitch preserved (WSOLA)
                self.stream = player = Player(speed)
                try:
                    async for resp in self.session.receive():
                        sc = resp.server_content
                        if sc and sc.output_transcription and sc.output_transcription.text:
                            said += sc.output_transcription.text
                            self.on_said(said)
                        if resp.data and still_current() and not player.stopped:
                            await asyncio.to_thread(player.write, resp.data)   # stopped: keep draining this turn
                        if sc and sc.turn_complete:
                            if still_current() and not player.stopped:
                                await asyncio.to_thread(player.write, b"", True)
                            break
                finally:
                    self.stream = None
                    player.close()
                return True
            except Exception as e:
                print("gemini voice error:", repr(e)[:200], flush=True)
                self.last_error = e
                await self._close()
                if "PortAudio" in repr(e):
                    break                 # audio device problem: let the server refresh devices, not reconnect
        return False


LEVEL_CB = None   # set by the server: receives output loudness 0..1 so the pet can pulse with the voice


class Player:
    """Streams 24kHz int16 PCM chunks to the speakers, sped up with pitch kept (WSOLA)."""
    BLOCK = 2400   # 0.1s per write, so a stop takes effect quickly

    def __init__(self, speed):
        self.stopped = False
        self.tsm = wsola(channels=1, speed=speed) if speed != 1.0 else None
        self.stream = sd.OutputStream(samplerate=24000, channels=1, dtype="float32")
        self.stream.start()

    def write(self, pcm, final=False):
        a = (np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0)[None, :]
        if self.tsm:
            r, w = ArrayReader(a), ArrayWriter(1)
            while not r.empty:
                self.tsm.read_from(r); self.tsm.write_to(w)
            if final:
                self.tsm.flush_to(w)
            a = w.data.astype(np.float32)
        out = a.T
        for i in range(0, len(out), self.BLOCK):
            if self.stopped:
                return
            block = np.ascontiguousarray(out[i:i + self.BLOCK])
            if LEVEL_CB:
                LEVEL_CB(min(1.0, float(np.sqrt(np.mean(block ** 2))) * 6))
            self.stream.write(block)

    def stop(self):
        self.stopped = True

    def close(self):
        if LEVEL_CB:
            LEVEL_CB(0.0)
        try:
            if self.stopped: self.stream.abort()
            else: self.stream.stop()
            self.stream.close()
        except Exception: pass


def tts(text, still_current, model, voice, speed, style, on_player):
    """Read `text` exactly as written with a Gemini TTS model, streaming. Returns True when spoken."""
    client = genai.Client(api_key=api_key(), http_options=types.HttpOptions(timeout=20000))   # ms; never hang forever
    cfg = types.GenerateContentConfig(response_modalities=["AUDIO"], speech_config=types.SpeechConfig(
        voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice))))
    player = Player(speed)
    on_player(player)                     # lets /stop abort playback
    try:
        for ch in client.models.generate_content_stream(model=model, contents=f"{style}: {text}", config=cfg):
            if not still_current() or player.stopped:
                break
            for p in (ch.candidates[0].content.parts if ch.candidates and ch.candidates[0].content else []):
                if p.inline_data and p.inline_data.data:
                    player.write(p.inline_data.data)
        if still_current():
            player.write(b"", final=True)
        return True
    finally:
        on_player(None)
        player.close()
