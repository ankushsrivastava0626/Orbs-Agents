# Installing Orbs Agents

The short version is in the [README](../README.md#install). This page covers each step, the permissions macOS will
ask for, the optional extras, updating and removing it.

## Before you start

| You need | Why | Get it |
|---|---|---|
| A Mac with Apple silicon, macOS 15 or later | The app is built for arm64 and uses event taps, Accessibility and Core Audio process taps | |
| Apple's Command Line Tools | `swiftc` builds the app on your Mac | `xcode-select --install` |
| [Homebrew](https://brew.sh) with `tmux` and `python@3.12` | Every orb is a tmux session; the voice server is Python | `brew install tmux python@3.12` |
| [Claude Code](https://code.claude.com/docs/en/overview), the native install (`~/.local/bin/claude`) | Each orb runs it | `curl -fsSL https://claude.ai/install.sh \| bash` |
| An [OpenRouter](https://openrouter.ai/keys) key with a little credit | Transcription, Joe's voice and the boards | openrouter.ai › Keys |

`jq` is used by the hooks. It ships with macOS 15, and the installer tells you if it's missing.

## 1. Get the code

Orbs Agents lives inside Claude Code's folder, because its hooks and scripts are found there:

```bash
git clone https://github.com/ankushsrivastava0626/Orbs-Agents ~/.claude/voice
```

## 2. Run the installer

```bash
~/.claude/voice/install.sh --dry-run
```

```bash
~/.claude/voice/install.sh
```

The installer is safe to run again; anything already done is left alone. It:

1. checks your Mac, macOS version and tools;
2. creates the Python environment `kitten-venv` and installs [`requirements.txt`](../requirements.txt) (a few hundred MB, mostly PyTorch for the speech check);
3. copies [`config.example`](../config.example) to `config` if you don't have one;
4. creates an empty key file `~/.claude/voice/.env` (readable only by you) if there isn't one;
5. adds three hooks to `~/.claude/settings.json` for `UserPromptSubmit`, `PreToolUse` and `Stop`. They run `~/.claude/voice/event.sh`, which tells the orbs what each session is doing and does nothing for sessions that aren't orbs. Your file is backed up to `settings.json.before-orbs` first;
6. builds and signs `VoicePet.app` (`pet/build.sh`);
7. installs two login agents, `com.claude.kitten-tts` (the voice server) and `com.claude.voice-pet` (the app), and starts them.

Options: `--no-login` skips step 7, `--no-build` skips step 6, and `--uninstall` removes it (see below).

## 3. Add your key

```bash
open -e ~/.claude/voice/.env
```

Fill in the one line and save:

```
OPENROUTER_API_KEY=sk-or-v1-…
```

The voice server reads this file each time it needs the key and never copies it anywhere. To keep the key somewhere
else, set `OPENROUTER_ENV=/path/to/your/.env` in `~/.claude/voice/config`.

## 4. Allow the permissions

| Permission | For | When macOS asks |
|---|---|---|
| **Accessibility** › VoicePet | The talk keys, double-taps, reading selected text, OS mode | Turn it on yourself in System Settings › Privacy & Security › Accessibility |
| **Microphone** › the voice server (Python) | Recording while you hold a key | The first time you hold a talk key |
| **System Audio Recording** › VoicePet | Meetings that record your Mac's audio too | The first meeting with *Record Mac audio* on |
| **Automation** › System Events, Terminal | Show in Terminal, and copying a selection that an app doesn't expose | The first time each is used |
| **Location** › VoicePet | Wi-Fi network names in OS mode's menu bar (macOS requires it) | When you open OS mode's Wi-Fi menu |

## 5. Start talking

Click **+** at the bottom right of your screen and pick **New Claude session** (or **New Claude session in folder…**).
When its orb appears, hold <kbd>1</kbd>, say what you want, and let go.

## A stable signing identity (recommended)

macOS ties the Accessibility permission to the app's signature. Without a signing identity, `build.sh` signs the app
*ad hoc*, and every rebuild (for example after `git pull`) asks for Accessibility again. A self-signed identity takes
a minute and fixes that:

1. Open **Keychain Access** › Keychain Access menu › **Certificate Assistant** › **Create a Certificate…**
2. Name: `VoicePet Local Signing` · Identity Type: **Self Signed Root** · Certificate Type: **Code Signing** › Create.
3. Rebuild once with `~/.claude/voice/pet/build.sh` and allow Accessibility one last time.

To use an identity with a different name, run `VOICEPET_SIGN_ID="Your identity" ~/.claude/voice/pet/build.sh`.

## Optional extras

**Transcribe on your Mac.** Install [MacParakeet](https://macparakeet.com) into `/Applications`, then pick
Voice › Transcription › **Local** in any orb's menu. Nothing you say leaves the Mac. Meetings then lose their speaker
labels. `KEEP_RESIDENT=on` keeps the model locked in memory on Macs where it gets swapped out.

**Joe on Gemini.** Store a Google AI key in your Keychain. The command asks for the key, so it stays out of your
shell history:

```bash
security add-generic-password -a "$USER" -s GEMINI_API_KEY -w
```

Then pick Voice › Joe's voice › **Gemini** in any orb's menu.

**Joe on-device (experimental).** `~/.claude/voice/kitten-venv/bin/pip install kittenml==0.9.3`, put the KittenTTS
model in your Hugging Face cache, set `ENGINE=kitten` in `config`, and restart the server (below).

**Other models.** **+** › **New orb with custom command…** runs any Claude Code–compatible command, for example a
small wrapper script that points Claude Code at OpenRouter. Orbs whose command mentions `openrouter` show rose and
can have their own system prompt.

**Codex.** Codex orbs talk to a companion Codex voice server on `127.0.0.1:5124`, which isn't published yet. Set
`CODEX_ROOT` to its folder when you have it.

## Day to day

| To | Run |
|---|---|
| Update | `git -C ~/.claude/voice pull && ~/.claude/voice/install.sh` |
| Restart the voice server | `launchctl kickstart -k gui/$(id -u)/com.claude.kitten-tts` |
| Restart the app | `launchctl kickstart -k gui/$(id -u)/com.claude.voice-pet` |
| Rebuild the app after changing Swift | `~/.claude/voice/pet/build.sh` |
| Read the logs | `tail -f /tmp/kitten-tts.log /tmp/voice-pet.log` |
| Check everything works | `~/.claude/voice/tests/smoke.sh` (speaks one short line; costs a fraction of a cent) |

## Uninstall

```bash
~/.claude/voice/install.sh --uninstall
```

This stops the voice server and the app, removes the two login agents and removes the three `event.sh` hooks from
`~/.claude/settings.json` (backing it up first). Your orbs' tmux sessions keep running (`tmux ls`), and your notes,
task cards and meetings stay in `~/.claude/voice`. Delete that folder to remove everything.
