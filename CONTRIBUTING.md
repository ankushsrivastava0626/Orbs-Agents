# Contributing to Orbs Agents

Thanks for helping. Bug reports, ideas, docs fixes and code are all welcome.

## Before you start

- **Bugs:** open an issue with your macOS version, Mac model, what you did, what happened, and the last lines of
  `/tmp/kitten-tts.log` and `/tmp/voice-pet.log`. Remove anything personal first: logs can contain what you said.
- **Features:** open an issue first for anything bigger than a small fix, so we can agree on the shape before you
  spend time on it.
- **Security problems:** please don't open an issue; follow [SECURITY.md](SECURITY.md).

## Set up

Install it as in [docs/INSTALL.md](docs/INSTALL.md); your clone at `~/.claude/voice` is also your working copy. Then:

| You changed | Run |
|---|---|
| Swift (`pet/`) | `pet/build.sh`: rebuilds, re-signs and restarts the app |
| Python or the hooks | `launchctl kickstart -k gui/$(id -u)/com.claude.kitten-tts` |
| The launcher | Nothing; the next orb you open uses it |

Make [a signing identity](docs/INSTALL.md#a-stable-signing-identity-recommended) once, or macOS will ask for
Accessibility again after every build.

## Test

```bash
tests/smoke.sh
```

It checks the server, the settings, Joe's voice and a task-card recording end to end. It speaks one short line
aloud, uses a fraction of a cent of OpenRouter credit, and leaves no cards or settings behind. For UI changes,
attach a short screen recording to your pull request.

## How the app should feel

These rules come from using it every day. Please keep to them:

1. **Native and calm.** System fonts, system-style animations, no decorative motion. Orbs breathe; they don't bounce.
2. **Icon-only buttons** on cards and boards, with a tooltip and an accessibility label.
3. **Color means state.** The orb colors are the interface (see the README). Board UI doesn't add yellow or blue accents of its own.
4. **Never take over the screen.** Nothing steals focus or covers your work unless you asked for it.
5. **No silent fallbacks.** If a provider fails, say so on the orb and keep the audio; don't quietly switch to something else.
6. **Interrupt, don't queue,** except Joe's lines, which play in order.
7. **Meetings stay discreet.** The meeting board is hidden from screen sharing, and the indicator is a dot.
8. **Keys stay in their file.** Never log, cache or copy an API key.

## Code

- **Swift:** AppKit and SwiftUI only, no packages. Keep blocking work (Accessibility calls, files, the network) off the main thread; the keyboard tap shares it.
- **Python:** standard library first; a new dependency needs a good reason and a pinned line in `requirements.txt`.
- **Shell:** bash, with absolute paths for anything launchd starts (it has a minimal `PATH`).
- **Data:** anything personal goes in a file that `.gitignore` already covers. Check `git status` before you commit.

## Pull requests

- One change per pull request, described the way a user would notice it ("Hover a busy orb to see its live steps").
- Commit messages follow the same style: what changed for the person using it, in plain words.
- Run `tests/smoke.sh` and say what you tested.

By contributing you agree that your work is released under the [MIT license](LICENSE), and that you'll follow the
[code of conduct](CODE_OF_CONDUCT.md).
