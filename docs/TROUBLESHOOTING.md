# Troubleshooting

Start with the logs. They usually say exactly what happened:

```bash
tail -n 50 /tmp/kitten-tts.log /tmp/voice-pet.log
```

## Every orb is grey

The voice server isn't running. Restart it, then check the log for the reason:

```bash
launchctl kickstart -k gui/$(id -u)/com.claude.kitten-tts
```

If it keeps stopping, run it in a terminal to see the error:

```bash
~/.claude/voice/kitten-venv/bin/python ~/.claude/voice/kitten_server.py
```

## An orb shows an orange dot

Something failed in the last two minutes. Hover the orb to read what. The common ones:

| Message | Fix |
|---|---|
| `no OpenRouter key file` / `no OPENROUTER_API_KEY` | Put `OPENROUTER_API_KEY=…` in `~/.claude/voice/.env`, or point `OPENROUTER_ENV` at your file |
| `402` or *exceed your available credits* | Add credit at openrouter.ai. Your recording is kept in `failed/`. |
| A provider error or timeout | It's retried once. If it keeps failing, switch Voice › Transcription to Local. |

## Holding a number key types the number

- VoicePet needs **Accessibility**: System Settings › Privacy & Security › Accessibility. If it's already on, turn it
  off and on again. This happens after an ad hoc rebuild; [a signing identity](INSTALL.md#a-stable-signing-identity-recommended)
  stops it.
- The key has to be held: a quick tap still types the number, and so does holding it with ⌘, ⌃, ⌥ or ⇧.
- Only slots that have an orb take their key.

## The orb turns red but nothing is heard

- Check `VOICE_MIC` in `config`. It's matched against your microphone's name; the default `MacBook` picks the built-in mic.
- Allow the microphone for the voice server: System Settings › Privacy & Security › Microphone.
- Recordings without speech are dropped on purpose, so speak for at least half a second.

## Joe is silent

- Check the orb isn't muted (speaker badge). Muted replies show as bubbles.
- Check the engine: Voice › Joe's voice in any orb's menu. Fish needs OpenRouter credit; Gemini needs `GEMINI_API_KEY` in your Keychain.
- Orbs speak through the `speak` tool. If a session was started before you installed, close it from its menu and open it again.

## The orb never turns purple or shows steps

The `event.sh` hooks aren't in `~/.claude/settings.json`. Run the installer again, which adds them:

```bash
~/.claude/voice/install.sh
```

## My Dock or menu bar stays hidden

OS mode hides them while it's on and puts them back when you leave it or quit VoicePet from its menu. If the app was
killed while OS mode was on, start it again and it restores them:

```bash
launchctl kickstart -k gui/$(id -u)/com.claude.voice-pet
```

## The build fails

- Install the Command Line Tools: `xcode-select --install`.
- A failed build starts the previous app again, so you're never left without it. Rebuild with the full output:

```bash
~/.claude/voice/pet/build.sh
```

## Still stuck?

Open an issue with your macOS version, Mac model and the last lines of both logs, with anything personal removed.
