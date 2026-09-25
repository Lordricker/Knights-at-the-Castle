#!/usr/bin/env bash
# Exports the demo builds into builds/ (git-ignored).
#   demo_windows/ — what gets uploaded to Steam.
#   demo_linux/   — NOT uploaded (Steam players get Windows under Proton); built
#                   anyway because it is the quickest way to test a real export here.
# Override the editor path with GODOT=/path/to/godot.
set -euo pipefail
GODOT="${GODOT:-$HOME/Documents/Program Apps/Godot_v4.7.1-stable_linux.x86_64}"
cd "$(dirname "$0")/../cadence-blade"
rm -rf ../builds/demo_windows ../builds/demo_linux
mkdir -p ../builds/demo_windows ../builds/demo_linux ../builds/steam_logs
"$GODOT" --headless --path . --export-release "Windows Demo"
"$GODOT" --headless --path . --export-release "Linux Demo"
# Ship the WebRTC library's third-party license notices with each build.
for d in ../builds/demo_windows ../builds/demo_linux; do
	mkdir -p "$d/licenses"
	cp addons/webrtc_native/LICENSE* "$d/licenses/"
done
