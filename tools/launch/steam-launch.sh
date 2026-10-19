#!/bin/bash
# Starts Baldur's Gate 3 from Steam with this checkout's quiet runtime.
#
# In Steam: Baldur's Gate 3 > Properties > General > Launch Options:
#   "/path/to/checkout/tools/launch/steam-launch.sh" #%command%
#
# Steam requires %command% for a wrapper and replaces it with the quoted app
# bundle; the "#" keeps that path (whose name has an apostrophe) out of the
# command, and the bundle is found here instead. The game is started through
# LaunchServices like a normal Steam launch, so it keeps its own access to
# ~/Documents, with the runtime injected next to Steam's own libraries (the
# overlay), the Larian launcher skipped and the Metal HUD loadable. Steam
# tracks the game until it quits.
#
# Optional build/steam-launch.env: KEY=VALUE lines added to the game's
# environment (for example BG3MFX_LAB=/absolute/path); BG3MFX_RUNTIME there
# selects another runtime library.
set -u
checkout="$(cd "$(dirname "$0")/../.." && pwd)"
runtime="$checkout/build/bin/libBG3MetalFX.dylib"
opener="${BG3MFX_OPEN:-/usr/bin/open}"

fail() {
    # Started by Steam, nobody sees stderr.
    [ -n "${SteamAppId:-}${STEAM_DYLD_INSERT_LIBRARIES:-}" ] &&
        /usr/bin/osascript -e "display alert \"BG3MFX could not start the game\" message \"$1\"" >/dev/null 2>&1
    echo "steam-launch: $1" >&2
    exit 1
}

extra=()
if [ -f "$checkout/build/steam-launch.env" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        if [ "${line%%=*}" = BG3MFX_RUNTIME ]; then runtime="${line#*=}"; else extra+=(--env "$line"); fi
    done < "$checkout/build/steam-launch.env"
fi
[ -f "$runtime" ] || fail "The runtime $runtime is missing. Run make in $checkout."

# The bundle Steam passed, if it arrived intact; otherwise the Steam libraries.
app=""
for argument in "$@"; do
    case "$argument" in *.app) [ -d "$argument" ] && app="$argument" ;; esac
done
if [ -z "$app" ]; then
    steam="$HOME/Library/Application Support/Steam"
    libraries=("$steam")
    while IFS= read -r path; do libraries+=("$path"); done < <(
        sed -n 's/^[[:space:]]*"path"[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' "$steam/steamapps/libraryfolders.vdf" 2>/dev/null)
    for library in "${libraries[@]}"; do
        candidate="$library/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
        if [ -d "$candidate" ]; then app="$candidate"; break; fi
    done
fi
[ -n "$app" ] || fail "Baldur's Gate 3 was not found in the Steam libraries."

inserts="$runtime"
[ -n "${STEAM_DYLD_INSERT_LIBRARIES:-}" ] && inserts="$STEAM_DYLD_INSERT_LIBRARIES:$runtime"
# Metal loads its HUD only when MTL_HUD_ENABLED is set at launch; it starts
# hidden unless BG3's Show Metal HUD checkbox was left on (as bg3mfx does).
hud=(--env MTL_HUD_ENABLED=1)
[ "$(/usr/bin/defaults read com.larian.bg3 BG3MFXMetalHUD 2>/dev/null)" = 1 ] || hud+=(--env MTL_HUD_HIDDEN=1)

exec "$opener" -n -W \
    --env "DYLD_INSERT_LIBRARIES=$inserts" \
    --env BG3MFX_ENABLE_METALFX=1 \
    --env SteamAppId=1086940 \
    --env SteamGameId=1086940 \
    "${hud[@]}" ${extra[@]+"${extra[@]}"} \
    "$app" --args -NoLauncher 1
