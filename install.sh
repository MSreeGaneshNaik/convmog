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
  B=$'\033[1m'; D=$'\033[2m'; O=$'\033[38;5;208m'; G=$'\033[38;5;77m'; R=$'\033[38;5;203m'; N=$'\033[0m'; CLR=$'\033[K'
else
  B=""; D=""; O=""; G=""; R=""; N=""; CLR=""
fi
STEP=0
TOTAL=9    # 4 here, then 5 in build.sh
step() { STEP=$((STEP + 1)); printf '\n%s[%s/%s]%s %s%s%s\n' "$O" "$STEP" "$TOTAL" "$N" "$B" "$*" "$N"; }   # what is happening
why()  { printf '      %s%s%s\n' "$D" "$*" "$N"; }                                                          # and why
ok()   { printf '      %s✓%s %s\n' "$G" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }
rep()  { local s="" n="$2"; while [ "$n" -gt 0 ]; do s="${s}${1}"; n=$((n - 1)); done; printf '%s' "$s"; }

# Runs "$@" quietly behind an animated bar sized for about $1 seconds; shows its output only if it fails.
bar() {
  local expect="$1"; shift
  if [ ! -t 1 ]; then "$@"; return; fi
  local log pid start=$SECONDS i=0 t fill
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
  log="$(mktemp)"
  "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    t=$((SECONDS - start))
    fill=$((t * 24 / expect)); [ "$fill" -gt 23 ] && fill=23
    printf '\r      %s%s %s%s%s%s %s%ss%s%s' "$O" "${frames[$((i % 10))]}" "$(rep ▰ "$fill")" "$D" "$(rep ▱ $((24 - fill)))" "$N" "$D" "$t" "$N" "$CLR"
    i=$((i + 1)); sleep 0.1
  done
  t=$((SECONDS - start))
  if wait "$pid"; then
    printf '\r      %s✓ %s%s %sdone in %ss%s%s\n' "$G" "$(rep ▰ 24)" "$N" "$D" "$t" "$N" "$CLR"
  else
    printf '\r%s' "$CLR"; cat "$log" >&2; return 1
  fi
}

# The petal mark, the name, and the finish cards (generated, so the box edges line up).
banner() {
  printf '\n'
  printf '    %s██▄▄ ██▄▄  ▄▄██ ▄▄██%s\n' "$O" "$N"
  printf '    %s████▄████▄▄████▄████%s\n' "$O" "$N"
  printf '    %s████████████████████%s    %sC O N V M O G%s\n' "$O" "$N" "$B" "$N"
  printf '    %s▀████▀████████▀████▀%s    %sby Jericho%s\n' "$O" "$N" "$D" "$N"
  printf '    %s ▀▀██ ▀▀████▀▀ ██▀▀ %s\n' "$O" "$N"
  printf '    %s ▄▄██ ▄▄████▄▄ ██▄▄ %s    %sHold ⇧ while dragging any file%s\n' "$O" "$N" "$N" "$N"
  printf '    %s▄████▄████████▄████▄%s    %sConverted beside the original,%s\n' "$O" "$N" "$D" "$N"
  printf '    %s████████████████████%s    %smade on your Mac, never uploaded.%s\n' "$O" "$N" "$D" "$N"
  printf '    %s████▀████▀▀████▀████%s\n' "$O" "$N"
  printf '    %s██▀▀ ██▀▀  ▀▀██ ▀▀██%s\n' "$O" "$N"
  printf '\n'
}
card_installed() {
  printf '\n    %s╭──────────────────────────────────────────────╮%s\n' "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s│%s  %s✓%s %sConvmog is ready%s                          %s│%s\n' "$D" "$N" "$G" "$N" "$B" "$N" "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s│%s  Drag any file, hold ⇧, drop on a format.    %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│%s  Menu bar petal mark → Open at Login         %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│%s  keeps it running. Run this line again       %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│%s  any time to update.                         %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s╰──────────────────────────────────────────────╯%s\n\n' "$D" "$N"
}
card_updated() {
  printf '\n    %s╭──────────────────────────────────────────────╮%s\n' "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s│%s  %s✓%s %sConvmog is updated%s                        %s│%s\n' "$D" "$N" "$G" "$N" "$B" "$N" "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s│%s  Your settings and login item are kept.      %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│%s  Run this line again any time to update.     %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s╰──────────────────────────────────────────────╯%s\n\n' "$D" "$N"
}
card_current() {
  printf '\n    %s╭──────────────────────────────────────────────╮%s\n' "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s│%s  %s✓%s %sConvmog is up to date%s                     %s│%s\n' "$D" "$N" "$G" "$N" "$B" "$N" "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s│%s  Nothing to download or rebuild.             %s│%s\n' "$D" "$N" "$D" "$N"
  printf '    %s│                                              │%s\n' "$D" "$N"
  printf '    %s╰──────────────────────────────────────────────╯%s\n\n' "$D" "$N"
}

banner

step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "Convmog is a Mac app — run this on macOS."
version="$(sw_vers -productVersion)"
[ "${version%%.*}" -ge 13 ] || die "Convmog needs macOS 13 Ventura or later (this Mac has ${version})."
ok "macOS ${version} on $(uname -m). Convmog needs macOS 13 or later."

step "Looking for the latest version on GitHub"
why "So a Mac that already has Convmog only rebuilds when something changed."
# The newest commit as a bare SHA. Offline or rate-limited → empty, and we simply reinstall.
latest="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${REPO}/commits/${BRANCH}" 2>/dev/null || true)"
[[ "$latest" =~ ^[0-9a-f]{40}$ ]] || latest=""
installed="$(defaults read "${APP}/Contents/Info" ConvmogCommit 2>/dev/null || true)"
short="${latest:0:7}"
had_app=0
[ -d "$APP" ] && had_app=1

if [ -z "$latest" ]; then
  why "GitHub didn't answer (offline or busy), so this does a full install of the newest code."
elif [ "$had_app" = 0 ]; then
  ok "Latest is ${short}. Convmog isn't installed yet, so it will be downloaded and built."
elif [ "$installed" = "$latest" ] && [ "${CONVMOG_FORCE:-0}" != "1" ]; then
  ok "You already have ${short}, the latest."
  if ! pgrep -x Convmog >/dev/null; then
    why "It wasn't running, so it's opening now."
    open "$APP"
  fi
  card_current
  exit 0
elif [ "$installed" = "$latest" ]; then
  ok "You already have ${short}, but CONVMOG_FORCE=1 asks for a rebuild anyway."
elif [ -n "$installed" ]; then
  ok "You have ${installed:0:7}, the latest is ${short}, so it will be updated."
else
  ok "You have an older Convmog without a version stamp, so it will be updated to ${short}."
fi

step "Checking for Apple's Swift compiler"
why "Convmog is built from its source on your Mac, so no prebuilt app is downloaded."
if ! xcrun --find swiftc >/dev/null 2>&1; then
  why "It needs Apple's free Command Line Tools, which aren't installed. Opening Apple's installer…"
  xcode-select --install >/dev/null 2>&1 || true
  die "Finish the install in the window that just opened, then paste the same command again."
fi
swift_version="$(xcrun swiftc --version 2>&1 | grep -o 'Apple Swift version [0-9.]*' | head -1 || true)"
[ -n "$swift_version" ] || swift_version="Apple Swift"
ok "Found ${swift_version}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
tag=""
[ -n "$short" ] && tag=" ${short}"

step "Downloading the source${tag}"
why "From github.com/${REPO}, into a temporary folder that is deleted when this finishes."
# Download exactly the commit we just checked, so the stamp in the app matches what was built.
url="https://codeload.github.com/${REPO}/tar.gz/${latest:-refs/heads/${BRANCH}}"
bar 3 bash -c 'set -o pipefail; curl -fsSL "$1" | tar -xz -C "$2"' _ "$url" "$TMP" \
  || die "Couldn't download from GitHub. Check your connection and try again."

cd "$TMP"/convmog-*
CONVMOG_STEP="$STEP" CONVMOG_TOTAL="$TOTAL" CONVMOG_COMMIT="$latest" ./build.sh --install

if [ "$had_app" = 1 ]; then card_updated; else card_installed; fi
