#!/bin/bash
# Rebuild VoicePet and sign it with the stable local identity, so macOS keeps its Accessibility permission.
set -e
cd "$(dirname "$0")"
launchctl bootout gui/$(id -u)/com.claude.voice-pet 2>/dev/null || true
B=$(mktemp -d)                                  # Swift needs the file with top-level code to be main.swift
cp VoicePet.swift "$B/main.swift"; cp OSMode.swift Dock.swift MenuBar.swift Sessions.swift Captions.swift TypeBox.swift Connectivity.swift "$B/"
swiftc -O -swift-version 5 -o VoicePet.app/Contents/MacOS/VoicePet "$B/main.swift" "$B/OSMode.swift" "$B/Dock.swift" "$B/MenuBar.swift" "$B/Sessions.swift" "$B/Captions.swift" "$B/TypeBox.swift" "$B/Connectivity.swift"
rm -rf "$B"
codesign --force --sign "VoicePet Local Signing" --identifier com.claude.voice-pet VoicePet.app
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.claude.voice-pet.plist
