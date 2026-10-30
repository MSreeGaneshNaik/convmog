#!/bin/bash
# Convmog installer — https://github.com/MSreeGaneshNaik/convmog
# Downloads the source, builds it on this Mac with Apple's Swift compiler,
# installs Convmog.app to /Applications and opens it. Nothing else is touched.
# Run it again any time: it checks the installed version against GitHub and
# only rebuilds when there's something new (CONVMOG_FORCE=1 rebuilds anyway).
set -euo pipefail

REPO="MSreeGaneshNaik/convmog"
BRANCH="${CONVMOG_BRANCH:-main}"
APP="/Applications/Convmog.app"

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; O=$'\033[38;5;208m'; G=$'\033[32m'; R=$'\033[31m'; N=$'\033[0m'
else
  B=""; D=""; O=""; G=""; R=""; N=""
fi
step() { printf '%s→%s %s\n' "$O" "$N" "$*"; }
die()  { printf '%s✗%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

printf '\n  %sConvmog%s  %sHold ⇧ while dragging any file%s\n\n' "$B" "$N" "$D" "$N"

[ "$(uname -s)" = "Darwin" ] || die "Convmog is a Mac app — run this on macOS."
version="$(sw_vers -productVersion)"
[ "${version%%.*}" -ge 13 ] || die "Convmog needs macOS 13 Ventura or later (this Mac has $version)."

# The newest commit on GitHub, as a bare SHA. Offline or rate-limited → empty, and we simply reinstall.
latest="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${REPO}/commits/${BRANCH}" 2>/dev/null || true)"
[[ "$latest" =~ ^[0-9a-f]{40}$ ]] || latest=""
installed="$(defaults read "${APP}/Contents/Info" ConvmogCommit 2>/dev/null || true)"

if [ -n "$latest" ] && [ "$installed" = "$latest" ] && [ "${CONVMOG_FORCE:-0}" != "1" ]; then
  printf '  %s✓%s Convmog is up to date %s(%s)%s\n\n' "$G" "$N" "$D" "${latest:0:7}" "$N"
  pgrep -x Convmog >/dev/null || open "$APP"
  exit 0
fi

if ! xcrun --find swiftc >/dev/null 2>&1; then
  step "Convmog builds from source, which needs Apple's free Command Line Tools."
  xcode-select --install >/dev/null 2>&1 || true
  die "Finish the install in the window that just opened, then paste the same command again."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

short="${latest:0:7}"
had_app=0
[ -d "$APP" ] && had_app=1
if [ "$had_app" = 1 ] && [ -n "$short" ]; then step "Updating Convmog to ${short}"
elif [ "$had_app" = 1 ]; then step "Updating Convmog"
else step "Downloading Convmog"
fi
# Download exactly the commit we just checked, so the stamp in the app matches what was built.
curl -fsSL "https://codeload.github.com/${REPO}/tar.gz/${latest:-refs/heads/${BRANCH}}" | tar -xz -C "$TMP" \
  || die "Couldn't download from GitHub. Check your connection and try again."

cd "$TMP"/convmog-*
step "Building on this Mac (about a minute)"
CONVMOG_COMMIT="$latest" ./build.sh --install
if [ "$had_app" = 1 ]; then
  printf '\n  %sUpdated.%s Your settings are kept.\n\n' "$G" "$N"
else
  printf '\n  %sDone.%s Drag any file, hold ⇧, and drop it on a format.\n' "$G" "$N"
  printf '  %sKeep it running: click the petal mark in the menu bar → Open at Login.%s\n\n' "$D" "$N"
fi
