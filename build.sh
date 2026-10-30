#!/bin/bash
# Builds Convmog.app with the Swift compiler that ships with Xcode's Command Line Tools.
#   ./build.sh            build and launch from ./build
#   ./build.sh --install  build, copy to /Applications, and launch
#   ./build.sh --check    build and self-test only (what CI runs)
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Convmog.app"
ARCH="$(uname -m)"
MODE="${1:-}"

if [ -t 1 ]; then
  B=$'\033[1m'; D=$'\033[2m'; O=$'\033[38;5;208m'; G=$'\033[38;5;77m'; R=$'\033[38;5;203m'; N=$'\033[0m'; CLR=$'\033[K'
else
  B=""; D=""; O=""; G=""; R=""; N=""; CLR=""
fi
# install.sh passes its step count in, so the numbering runs on across both scripts.
STEP="${CONVMOG_STEP:-0}"
TOTAL="${CONVMOG_TOTAL:-5}"
[ "$MODE" = "--check" ] && [ -z "${CONVMOG_TOTAL:-}" ] && TOTAL=4
step() { STEP=$((STEP + 1)); printf '\n%s[%s/%s]%s %s%s%s\n' "$O" "$STEP" "$TOTAL" "$N" "$B" "$*" "$N"; }   # what is happening
why()  { printf '      %s%s%s\n' "$D" "$*" "$N"; }                                                          # and why
ok()   { printf '      %s✓%s %s\n' "$G" "$N" "$*"; }
die()  { printf '\n%s✗ %s%s\n\n' "$R" "$*" "$N" >&2; exit 1; }
rep()  { local s="" n="$2"; while [ "$n" -gt 0 ]; do s="${s}${1}"; n=$((n - 1)); done; printf '%s' "$s"; }

# Runs "$@" quietly behind an animated bar sized for about $1 seconds, so a long silent step never
# looks stuck; shows its output only if it fails.
bar() {
  local expect="$1"; shift
  if [ ! -t 1 ]; then "$@"; return; fi
  local log="build/step.log" pid start=$SECONDS i=0 t fill
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
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

command -v swiftc >/dev/null 2>&1 || die "swiftc not found. Install the Command Line Tools first:  xcode-select --install"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

step "Compiling Convmog for ${ARCH}"
why "Apple's Swift compiler turns the source into a native app for this Mac. This is the slow part."
bar 40 swiftc -O -parse-as-library -swift-version 5 -suppress-warnings \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target "${ARCH}-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/Convmog" \
  || die "The compiler stopped with the errors above. Please open an issue on github.com/MSreeGaneshNaik/convmog with them."

step "Putting the app together"
why "Adding its settings file, its version stamp and its icon in every size macOS uses."
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Stamp the commit this build came from, so install.sh can tell whether an update is needed.
if [ -z "${CONVMOG_COMMIT:-}" ] && git rev-parse HEAD >/dev/null 2>&1; then
  CONVMOG_COMMIT="$(git rev-parse HEAD)"
  git diff --quiet HEAD 2>/dev/null || CONVMOG_COMMIT="${CONVMOG_COMMIT}-dirty"
fi
plutil -insert ConvmogCommit -string "${CONVMOG_COMMIT:-unknown}" "$APP/Contents/Info.plist"
# App icon: one 1024px master → every size macOS wants (sips + iconutil are built in).
if [ -f Resources/AppIcon.png ]; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET" && mkdir -p "$ICONSET"
  for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s*2)) $((s*2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || why "(icon skipped)"
fi
version="${CONVMOG_COMMIT:-unknown}"
ok "Version ${version:0:7}"

step "Signing it for this Mac"
why "A local signature, so macOS lets an app you built yourself run."
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true
ok "Signed"

step "Running the self-test"
why "It checks the wheel maths, file naming, and real Flip and Crop runs before anything is installed."
result="$("$APP/Contents/MacOS/Convmog" --selftest 2>&1)" \
  || { printf '%s\n' "$result" >&2; die "Self-test failed, so this build was not installed. Your current Convmog is untouched."; }
ok "All checks passed"
[ "$MODE" = "--check" ] && { ok "Built ${APP}"; exit 0; }

if [ "$MODE" = "--install" ]; then
  step "Installing to /Applications"
  why "Replacing the app keeps your settings; they live in macOS preferences, not inside the app."
else
  step "Opening it from ./build"
  why "A trial run; ./build.sh --install puts it in /Applications."
fi
if [ "$MODE" = "--install" ]; then
  # Copy the new app in beside the old one first, so a failed copy (a full disk) leaves the old one working.
  rm -rf /Applications/Convmog.app.new
  cp -R "$APP" /Applications/Convmog.app.new || die "Couldn't copy into /Applications. Your current Convmog is untouched."
fi
if pgrep -x Convmog >/dev/null 2>&1; then
  pkill -x Convmog 2>/dev/null || true
  ok "Quit the running Convmog so the new one can take its place"
  sleep 0.3
fi
if [ "$MODE" = "--install" ]; then
  rm -rf /Applications/Convmog.app
  mv /Applications/Convmog.app.new /Applications/Convmog.app
  open /Applications/Convmog.app
  ok "Installed and opened. Look for the petal mark in the menu bar."
else
  open "$APP"
  ok "Opened. Look for the petal mark in the menu bar, then hold ⇧ while dragging any file."
fi
