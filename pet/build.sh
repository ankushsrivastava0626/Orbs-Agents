#!/bin/bash
# Build VoicePet.app, the Orbs Agents app, from the Swift sources and sign it.
# With a stable signing identity — "VoicePet Local Signing" by default, or set VOICEPET_SIGN_ID — macOS keeps the
# app's Accessibility and Input Monitoring permissions across rebuilds. Without one the app is signed ad hoc and
# macOS asks for those permissions again after every rebuild (docs/INSTALL.md shows how to make an identity).
set -e
cd "$(dirname "$0")"
ID="${VOICEPET_SIGN_ID:-VoicePet Local Signing}"
security find-identity -p codesigning 2>/dev/null | grep -qF "\"$ID\"" || {
  echo "build.sh: no \"$ID\" code-signing identity in your keychain; signing ad hoc."; ID=-; }
PLIST="$HOME/Library/LaunchAgents/com.claude.voice-pet.plist"
UID_GUI="gui/$(id -u)"
restart() { [ -z "$CI" ] && [ -f "$PLIST" ] && launchctl bootstrap "$UID_GUI" "$PLIST" 2>/dev/null; return 0; }
[ -n "$CI" ] || launchctl bootout "$UID_GUI/com.claude.voice-pet" 2>/dev/null || true
trap 'echo "build.sh: build failed; the previous VoicePet is started again." >&2; restart' ERR
mkdir -p VoicePet.app/Contents/MacOS
B=$(mktemp -d)                                  # Swift needs the file with top-level code to be main.swift
cp VoicePet.swift "$B/main.swift"; cp OSMode.swift Dock.swift MenuBar.swift Sessions.swift Captions.swift TypeBox.swift Connectivity.swift SessionSearch.swift Canvas.swift TaskTimer.swift SelectionReader.swift OrbStrip.swift Pomodoro.swift MeetingBadge.swift MeetingBoard.swift SystemAudio.swift TaskBoard.swift "$B/"
swiftc -O -swift-version 5 -o VoicePet.app/Contents/MacOS/VoicePet "$B/main.swift" "$B/OSMode.swift" "$B/Dock.swift" "$B/MenuBar.swift" "$B/Sessions.swift" "$B/Captions.swift" "$B/TypeBox.swift" "$B/Connectivity.swift" "$B/SessionSearch.swift" "$B/Canvas.swift" "$B/TaskTimer.swift" "$B/SelectionReader.swift" "$B/OrbStrip.swift" "$B/Pomodoro.swift" "$B/MeetingBadge.swift" "$B/MeetingBoard.swift" "$B/SystemAudio.swift" "$B/TaskBoard.swift"
rm -rf "$B"
codesign --force --sign "$ID" --identifier com.claude.voice-pet VoicePet.app
trap - ERR
restart
