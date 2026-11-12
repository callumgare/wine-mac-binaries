#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# archive.sh <flavour> <version>
#
# Packs the release tree and its debug symbols into reproducible tarballs in
# out/, and writes SHA256SUMS for everything there for this build.

source "$(dirname "$0")/lib.sh"

[[ $# -eq 2 ]] || die "usage: archive.sh <flavour> <version>"
FLAVOUR="$1"; VERSION="$2"
load_build_inputs "$FLAVOUR" "$VERSION"
export PATH; PATH="$(clean_path)"

PKG="$WMB_WORK_DIR/$BUILD_ID/pkg"
[[ -f "$PKG/$BUILD_ID/BUILD-INFO.json" ]] || die "no packaged build at $PKG; run package.sh and manifest.sh first"

group_start "Archive"
deterministic_tar "$PKG" "$BUILD_ID" "$WMB_OUT_DIR/$BUILD_ID.tar.xz" "$WINE_RELEASE_EPOCH"
deterministic_tar "$PKG" "$BUILD_ID-debug" "$WMB_OUT_DIR/$BUILD_ID-debug.tar.xz" "$WINE_RELEASE_EPOCH"
(
    cd "$WMB_OUT_DIR"
    shasum -a 256 "$BUILD_ID".tar.xz "$BUILD_ID"-debug.tar.xz "$BUILD_ID".build-info.json "$BUILD_ID".spdx.json \
        > "$BUILD_ID.SHA256SUMS"
    cat "$BUILD_ID.SHA256SUMS"
    ls -l "$BUILD_ID"*
)
group_end
