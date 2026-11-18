# Security

Orbs Agents holds your microphone, can press keys for you, and runs coding agents on your Mac, so we take security
reports seriously.

## Reporting a problem

Please don't open a public issue. Use GitHub's **Report a vulnerability** (Security tab) on this repository, or
contact the maintainer privately through [GitHub](https://github.com/ankushsrivastava0626). Include what you found,
how to reproduce it and what it lets someone do. You'll get an answer within a few days, and credit in the fix if you
want it.

Only the latest `main` is supported.

## What Orbs Agents can reach

| It uses | For | Granted by |
|---|---|---|
| The microphone | Recording while you hold a talk key, in auto mode, and during meetings | You, in Privacy & Security › Microphone |
| Accessibility | Watching the talk keys, reading selected text, arranging windows in OS mode | You, in Privacy & Security › Accessibility |
| System audio | Recording the Mac's audio in meetings, if *Record Mac audio* is on | You, in Privacy & Security › System Audio Recording |
| Your Claude Code sessions | Typing what you said into the orb you were talking to | Running them in tmux on your account |

## What stays on your Mac

- **The voice server listens on `127.0.0.1:5123` only.** It returns `403` for any request with an `Origin` header (that is, from a web page) or a `Host` that isn't local, which blocks cross-site requests and DNS rebinding. Like any local service, it trusts other programs running under your account.
- **Your data is plain files** in `~/.claude/voice`: orbs, notes, task cards, meeting transcripts, failed recordings. `.gitignore` keeps all of them, and `config` and `.env`, out of git.
- **With local transcription** (Parakeet), your speech never leaves the Mac.

## What leaves your Mac

- **Audio and text go to OpenRouter** for transcription, Joe's voice and the boards, but only after a local speech check confirms someone is talking. Every request asks for `zdr: true` and `data_collection: deny`, so OpenRouter only routes to providers with zero data retention that don't train on it.
- **Gemini voice** (optional) talks to Google directly with your own key.
- **Your coding agents** send whatever they send. Orbs run ordinary Claude Code sessions under your account and settings.

## Keys

- The OpenRouter key is read from the file you chose (`OPENROUTER_ENV`, default `~/.claude/voice/.env`, created readable only by you) each time it's needed, and is never stored elsewhere, cached or logged.
- The Gemini key lives in your Keychain.
- Orb sessions are told, in `voice-system-prompt.md`, to say what they're about to do and wait for your spoken yes before anything irreversible or outward-facing.
