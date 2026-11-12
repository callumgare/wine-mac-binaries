#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# manifest.sh <flavour> <version>
#
# Writes BUILD-INFO.json, LICENSES/ and README.md into the release tree, and
# out/<build id>.build-info.json and out/<build id>.spdx.json.

source "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "usage: manifest.sh <flavour> <version>"
FLAVOUR="$1"; VERSION="$2"
load_build_inputs "$FLAVOUR" "$VERSION"
load_toolchain "$TOOLCHAIN"
export PATH; PATH="$(clean_path)"

export W="$WMB_WORK_DIR/$BUILD_ID"
export T="$W/pkg/$BUILD_ID"
export WMB_ROOT WMB_OUT_DIR TC BUILD_ID BUILD_NAME FLAVOUR FLAVOUR_DESCRIPTION BUILD_REVISION TOOLCHAIN \
    DEPLOYMENT_TARGET WINE_VERSION WINE_URL WINE_SHA256 WINE_SIGNING_KEY WINE_RELEASE_EPOCH \
    GECKO_VERSION GECKO_X86_URL GECKO_X86_SHA256 GECKO_X86_64_URL GECKO_X86_64_SHA256 \
    MONO_VERSION MONO_URL MONO_SHA256
export PATCHES="${PATCHES[*]}"
export WMB_REPO_URL="${WMB_REPO_URL:-$(git -C "$WMB_ROOT" remote get-url origin 2>/dev/null | sed 's|\.git$||; s|^git@github.com:|https://github.com/|' || true)}"

group_start "Manifest"
/usr/bin/python3 -I "$WMB_ROOT/build/manifest.py"
group_end
