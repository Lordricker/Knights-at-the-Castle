#!/usr/bin/env bash
# Uploads builds/demo_windows and builds/demo_linux to Steam (run build_demo.sh first).
# Usage: steam/upload_demo.sh <steam_username>   (asks for password + Steam Guard code)
# Afterwards set the new build live on a branch in Steamworks > SteamPipe > Builds.
set -euo pipefail
[ $# -eq 1 ] || { echo "usage: $0 <steam_username>"; exit 1; }
STEAMCMD="${STEAMCMD:-$HOME/steamcmd/steamcmd.sh}"
cd "$(dirname "$0")"
"$STEAMCMD" +login "$1" +run_app_build "$PWD/app_build_demo.vdf" +quit
