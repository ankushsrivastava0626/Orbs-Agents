# Changelog

Everything notable, newest first. Dates are when it landed on `main`.

## 2026-11-18: ready for others

- `install.sh` sets everything up on a fresh Mac (with `--dry-run` and `--uninstall`), and `config.example`, the
  login-agent templates and the `speak` tool's config work from any home folder.
- Paths that were tied to one Mac are now settings: `OPENROUTER_ENV`, `NOTES_FILE`, `DEFAULT_CWD`, `CODEX_ROOT`, and
  `moved.json` for folders that moved.
- The voice server starts without a config file, and `pet/build.sh` builds on a fresh clone (signing ad hoc when
  there's no identity, and restarting the previous app if a build fails).
- `requirements.txt` lists only what the code imports.
- README, docs, website, and contributing and security guides.

## 2026-11-17: smoother and clearer

- Hover a busy orb to see a live card: elapsed time, what it's doing now, and the steps before.
- New coral *transcribing* state with a spinning arc, and the working arc really spins.
- Interrupt instead of queue: a newer hold to the same orb replaces an unsent recording; a new task card replaces one
  still being transcribed. Joe's lines still play in order.
- Switch Joe's voice (Fish Audio or Gemini) and transcription (cloud or local) from the orb menu.
- A failed transcription keeps your audio and says why on the orb, with one retry on network blips.
- Much lighter app: it redraws only on change and polls less when idle. Plus keep-alive HTTP, and speaker muting off
  the key tap.
- `tests/smoke.sh`, an end-to-end check.

## 2026-11-15: new voices

- Joe speaks with Fish Audio Drama 3, sentence by sentence.
- Commands, notes and task cards transcribe with AssemblyAI Universal 3.6 Pro; meetings with ElevenLabs Scribe v2
  and speaker labels.
- Every OpenRouter request asks for zero data retention and no data collection, fastest provider first.
- The boards use MiniMax M3.1 Flash.

## 2026-11-04 to 11-09

- Session search browses folders, then models, then conversations.
- Per-conversation system prompts for OpenRouter orbs.
- Orbs from CUE Studio agents.
- Resumed conversations come back on their own model, command and folder, even after the folder moved.
- A reorganised orb menu.

## 2026-10-26 to 10-28: meetings and task cards

- **Meetings.** Double-tap right ⌥ to record your mic and Mac audio in a separate recorder process. You get
  speaker-labelled transcripts, a live meeting board with prompts and Ask, and previous meetings.
- **Task cards.** Hold ` to dictate. AI reshapes your words into a prompt, and you can flip between the two versions.
  There's one window per card, plus a quick look in the top-left corner.
- **Custom-command orbs,** for example Claude Code on OpenRouter, shown in rose.

## 2026-10-06 to 10-21: the first orbs

- Push to talk per orb on <kbd>1</kbd>–<kbd>0</kbd>, notes on left ⌥, a typing box, bubbles, orb colors for every
  state, and drag to reorder.
- OS mode, with its own menu bar, dock, app dial, Wi-Fi and Bluetooth.
- The orb strip outside OS mode.
- Canvas, read-aloud, the task timer, the focus timer and session search.
