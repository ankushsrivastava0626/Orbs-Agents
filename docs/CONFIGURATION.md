# Settings

Orbs Agents reads `~/.claude/voice/config`. The installer creates it from [`config.example`](../config.example).

- **Format.** One `KEY=value` per line; anything after `#` is a comment. Shell scripts read the same file, so put
  quotes around values with spaces.
- **When changes apply.** The voice server re-reads most settings on every use. A few are read when it starts; restart
  it after changing those (`launchctl kickstart -k gui/$(id -u)/com.claude.kitten-tts`).
- **From the orb menu.** Voice › Joe's voice and Voice › Transcription change `ENGINE` and `STT_ENGINE` for you.

## Your key

| Setting | Default | What it does |
|---|---|---|
| `OPENROUTER_ENV` | `~/.claude/voice/.env` | The file holding `OPENROUTER_API_KEY=…`. Read on every request, never copied. |

## Speech to text

| Setting | Default | What it does |
|---|---|---|
| `STT_ENGINE` | `cloud` | `cloud` uses OpenRouter. `local` uses Parakeet through MacParakeet on your Mac. Neither falls back to the other. |
| `STT_MODEL` | `assemblyai/universal-3-6-pro` | Model for commands, notes and task cards |
| `MEETING_STT_MODEL` | `elevenlabs/scribe-v2` | Model for meetings, with speaker labels |
| `VOICE_MIC` | `MacBook` | Part of the name of the microphone to record from. The built-in mic keeps AirPods out of low-quality call mode. |
| `KEEP_RESIDENT` | `off` | `on` locks the local speech model in memory (useful on 8 GB Macs). Read at start. |

## Joe, the voice

| Setting | Default | What it does |
|---|---|---|
| `ENGINE` | `fish` | `fish` (Fish Audio Drama 3 via OpenRouter), `gemini` (Gemini Live, key in Keychain) or `kitten` (on-device) |
| `FISH_MODEL` | `fish-audio/drama-3` | Fish Audio model on OpenRouter |
| `FISH_VOICE` | `ffe96076aeaf4da6b13b5f204ba1445b` | Fish Audio voice id |
| `FISH_SPEED` | `1.0` | Playback speed; above 1 is faster with the pitch kept |
| `GEMINI_MODEL` | `models/gemini-3.8-live` | Gemini Live model |
| `GEMINI_VOICE` | `Orus` | Gemini prebuilt voice |
| `GEMINI_SPEED` | `1.0` | Playback speed, pitch kept |
| `KITTEN_MODEL` | `KittenML/kitten-tts-nano-0.8-int8` | KittenTTS model (read at start) |
| `KITTEN_VOICE` | `Jasper` | KittenTTS voice |
| `KITTEN_SPEED` | `1.0` | KittenTTS speed |

Joe's character is in [`persona.txt`](../persona.txt). How orb sessions talk to you, as Joe and only through the
`speak` tool, is in [`voice-system-prompt.md`](../voice-system-prompt.md).

## Boards

| Setting | Default | What it does |
|---|---|---|
| `MEETING_MODEL` | `minimax/minimax-m3.1-flash` | Rewrites task cards and answers meeting-board prompts |

## Orbs and input

| Setting | Default | What it does |
|---|---|---|
| `DEFAULT_CWD` | your home folder | Folder a new orb starts in when you don't pick one |
| `NOTES_FILE` | `~/.claude/voice/notes/notes.md` | Notes mode appends one timestamped line per thing you say |
| `PTT_SOURCE` | `pet` | `pet`: the app reports the talk keys. `server`: the server watches left ⌥ itself (no app needed). |
| `VOICE_TMUX_TARGET` | `voice` | tmux session that gets auto-mode speech |
| `VOICE_BARGE_IN` | `off` | `on`: in auto mode, talking interrupts Joe. Use with headphones only, or speakers will echo. |
| `CODEX_ROOT` | empty | Folder of the optional Codex voice server (Codex orbs). Read at start. |

## Legacy narration hooks

These only matter if you also wire `speak-step.sh`, `speak-reply.sh` or `speak-notify.sh` into Claude Code yourself.

| Setting | Default | What it does |
|---|---|---|
| `VOICE` | `Samantha` | macOS `say` voice used when the voice server is down |
| `RATE` | `200` | `say` speed |
| `MAX_SENTENCES` | `2` | Longest narration, in sentences |
| `VOICE_ONLY_IN` | empty | Only narrate sessions under these folders, separated by `\|`; empty means all |

## Folders that moved

When you move a project folder, its conversations still point at the old path. List your moves in
`~/.claude/voice/moved.json` and orbs resume those conversations from the new place:

```json
{ "~/old/projects": "~/new/projects" }
```

## Files Orbs Agents writes

Everything stays in `~/.claude/voice`, and git ignores all of it.

| Path | Holds |
|---|---|
| `orbs.json`, `session.json`, `sessions.json`, `orb_names.json`, `last_said.json` | Your orbs, recent launches, names you gave them, each orb's last line |
| `prompts/<conversation>.md` | Per-conversation system prompts for OpenRouter orbs |
| `tasks/` | Task cards (`cards.json`), their recordings and original words, deleted cards |
| `meetings/<time>/` | Meeting transcripts (`.txt`, `.srt`, `.json`) and prompt replies. The audio is deleted once the transcript is saved. |
| `notes/notes.md` | Notes, unless `NOTES_FILE` points elsewhere |
| `failed/` | Recordings that couldn't be transcribed, kept so nothing you said is lost |
| `spool/`, `run/`, `cache/`, `timelog/` | Lines waiting for the server, launch scripts, the search index, the task timer's log |
| `/tmp/kitten-tts.log`, `/tmp/voice-pet.log` | Logs |
