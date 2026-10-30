#!/bin/bash
# Convmog installer — https://github.com/MSreeGaneshNaik/convmog
# Downloads the source, builds it on this Mac with Apple's Swift compiler,
# installs Convmog.app to /Applications and opens it. Nothing else is touched.
set -euo pipefail

REPO="MSreeGaneshNaik/convmog"
BRANCH="${CONVMOG_BRANCH:-main}"

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

if ! xcrun --find swiftc >/dev/null 2>&1; then
  step "Convmog builds from source, which needs Apple's free Command Line Tools."
  xcode-select --install >/dev/null 2>&1 || true
  die "Finish the install in the window that just opened, then paste the same command again."
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step "Downloading the source"
curl -fsSL "https://codeload.github.com/$REPO/tar.gz/refs/heads/$BRANCH" | tar -xz -C "$TMP" \
  || die "Couldn't download from GitHub. Check your connection and try again."

cd "$TMP"/convmog-*
step "Building on this Mac (about a minute)"
./build.sh --install
printf '\n  %sDone.%s Drag any file, hold ⇧, and drop it on a format.\n' "$G" "$N"
printf '  %sKeep it running: click ◌ in the menu bar → Open at Login.%s\n\n' "$D" "$N"
