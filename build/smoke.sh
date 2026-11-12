#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# smoke.sh <flavour> <version>
#
# Runs the packaged release tree the way a user's Mac would: in a sandbox
# that can't see the toolchain (/opt/wmb) or any other place libraries might
# come from (/opt/local, /usr/local, /opt/homebrew, /Library/Frameworks). It
# fails the build unless
#
#   - wine --version names the version built,
#   - wineboot makes a prefix, and cmd and reg run in it,
#   - every library loaded is the tree's own or macOS's,
#   - MoltenVK loads from the tree (Vulkan finds its driver).
#
# File comparison can't see these: a weak import of a function the minimum
# macOS lacks crashed every process, and a Vulkan loader that only found
# MoltenVK through the toolchain looked fine in the build VM (plan.md,
# "Found while building").

source "$(dirname "$0")/lib.sh"
require_x86_64 "$@"

[[ $# -eq 2 ]] || die "usage: smoke.sh <flavour> <version>"
FLAVOUR="$1"; VERSION="$2"
load_build_inputs "$FLAVOUR" "$VERSION"
export PATH; PATH="$(clean_path)"

W="$WMB_WORK_DIR/$BUILD_ID"
T="$W/pkg/$BUILD_ID"
[[ -x "$T/bin/wine" ]] || die "no packaged build at $T; run package.sh first"
LOG="$W/smoke"
rm -rf "$LOG"; mkdir -p "$LOG"

export WINEPREFIX="$LOG/prefix" WINEDEBUG=-all
unset WINEARCH WINEDLLPATH WINELOADER VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH

PROFILE='(version 1)
(allow default)
(deny file-read* file-write*
    (subpath "/opt/wmb") (subpath "/opt/local") (subpath "/usr/local")
    (subpath "/opt/homebrew") (subpath "/Library/Frameworks"))'

# run <seconds> <log name> <command...>: in the sandbox, with a time limit,
# printing every library loaded to <log name>.log. (perl sets the dyld
# variable itself: SIP strips DYLD_* when it starts a system binary.)
run() {
    local secs="$1" name="$2"; shift 2
    sandbox-exec -p "$PROFILE" /usr/bin/perl -e \
        '$ENV{DYLD_PRINT_LIBRARIES} = 1; alarm shift; exec @ARGV or die "exec: $!"' \
        "$secs" "$@" > "$LOG/$name.log" 2>&1
}
stop_wine() { sandbox-exec -p "$PROFILE" "$T/bin/wineserver" -k >/dev/null 2>&1 || true; }
trap stop_wine EXIT

fail() { stop_wine; die "smoke test: $*"; }
step() { log "smoke: $*"; }

step "wine --version"
run 60 version "$T/bin/wine" --version || fail "wine --version failed (see $LOG/version.log)"
grep -q -x "wine-$WINE_VERSION.*" <(grep -v '^dyld' "$LOG/version.log") ||
    fail "wine --version says '$(grep -v '^dyld' "$LOG/version.log")', expected wine-$WINE_VERSION"

step "wineboot (new prefix)"
run 600 wineboot "$T/bin/wine" wineboot -u || fail "wineboot failed or timed out (see $LOG/wineboot.log)"
n="$(ls "$WINEPREFIX/drive_c/windows/system32" 2>/dev/null | wc -l | tr -d ' ')"
[[ $n -gt 100 ]] || fail "the new prefix's system32 has only $n files"

step "cmd"
run 120 cmd "$T/bin/wine" cmd /c "echo smoke-ok & ver" || fail "cmd failed (see $LOG/cmd.log)"
grep -q smoke-ok "$LOG/cmd.log" || fail "cmd printed nothing (see $LOG/cmd.log)"

step "reg"
run 120 reg "$T/bin/wine" reg query 'HKLM\Software\Microsoft\Windows NT\CurrentVersion' /v ProductName ||
    fail "reg query failed (see $LOG/reg.log)"
grep -q ProductName "$LOG/reg.log" || fail "reg query found no ProductName (see $LOG/reg.log)"
stop_wine

# --- What was loaded --------------------------------------------------------
# dyld prints "dyld[pid]: <uuid> /path". Several processes write at once, so
# a line can be cut into another; only whole lines are judged.
cat "$LOG"/*.log | sed -n -E 's|^dyld\[[0-9]+\]: <[0-9A-F-]+> (/.*)$|\1|p' | grep -v 'dyld\[' | sort -u > "$LOG/loaded.txt"
[[ -s "$LOG/loaded.txt" ]] || fail "dyld printed no libraries; can't check where they came from"

step "everything loaded is the build's own or macOS's"
grep -v -E "^($T/|/System/|/usr/lib/|/usr/libexec/rosetta/|/Library/Apple/)" "$LOG/loaded.txt" > "$LOG/outside.txt" || true
if [[ -s "$LOG/outside.txt" ]]; then
    cat "$LOG/outside.txt" >&2
    fail "the libraries above came from outside the build"
fi

step "MoltenVK loads from the build"
grep -q -x "$T/lib/libMoltenVK.dylib" "$LOG/loaded.txt" ||
    fail "MoltenVK wasn't loaded from $T/lib, so Vulkan has no driver"

log "Smoke test passed ($(wc -l < "$LOG/loaded.txt" | tr -d ' ') libraries loaded, $(grep -c "^$T/" "$LOG/loaded.txt") of them the build's own)"
rm -rf "$WINEPREFIX"
