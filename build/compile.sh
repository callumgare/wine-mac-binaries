#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# compile.sh <flavour> <version>
#
# Fetches and patches the source, then configures, builds and installs Wine
# into work/<build id>/install. Packaging is build/package.sh.

source "$(dirname "$0")/lib.sh"
require_x86_64 "$@"

[[ $# -eq 2 ]] || die "usage: compile.sh <flavour> <version>"
FLAVOUR="$1"; VERSION="$2"
load_build_inputs "$FLAVOUR" "$VERSION"
load_toolchain "$TOOLCHAIN"
[[ -f "$TC/.complete" ]] || die "toolchain $TOOLCHAIN isn't installed at $TC; run: ./wmb toolchain $TOOLCHAIN"

W="$WMB_WORK_DIR/$BUILD_ID"
SRC="$W/src"
INSTALL="$W/install"
# Paths embedded in debug info and assertions are rewritten to this, so the
# build directory (a home folder, a VM path) doesn't leak into the binaries,
# and two builds in different places produce the same bytes.
MAPPED_SRC="/wmb/src/$BUILD_NAME"
PREFIX="/opt/wmb/wine"   # never used at run time; Wine finds its files relative to itself

# --- Source --------------------------------------------------------------------
group_start "Source: wine $WINE_VERSION"
rm -rf "$W"; mkdir -p "$W"
tar -xJf "$(fetch "$WINE_URL" "$WINE_SHA256")" -C "$W"
mv "$W/wine-$WINE_VERSION" "$SRC"
group_end

group_start "Patches"
for p in "${PATCHES[@]}"; do
    log "Applying $p"
    patch -d "$SRC" -p1 --forward --batch < "$WMB_ROOT/$p"
done
group_end

# --- Environment ---------------------------------------------------------------
# Only the OS, Xcode and the toolchain. llvm-mingw goes last so its own
# `clang` never shadows Xcode's for the Mac side.
export PATH="$TC/bin:$(clean_path):$TC/libexec/llvm-mingw/bin"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
export SOURCE_DATE_EPOCH="$WINE_RELEASE_EPOCH"
export ZERO_AR_DATE=1
# winegcc's temp directory path ends up in every PDB (patch 0003 makes its
# name deterministic); keep it off the per-user /var/folders path too.
export TMPDIR="/tmp/wmb-$BUILD_ID"
rm -rf "$TMPDIR"; mkdir -p "$TMPDIR"
export PKG_CONFIG="$TC/bin/pkg-config"
export PKG_CONFIG_LIBDIR="$TC/lib/pkgconfig:$TC/share/pkgconfig"
unset PKG_CONFIG_PATH CPATH LIBRARY_PATH DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH

PREFIX_MAP="-ffile-prefix-map=$SRC=$MAPPED_SRC"
CC="/usr/bin/clang -arch x86_64"
CXX="/usr/bin/clang++ -arch x86_64"
# -O2 as Gcenx's Portfile. -g only adds debug info, which package.sh moves
# into the debug-symbols asset; the shipped binaries end up without it.
CFLAGS="-O2 -g $PREFIX_MAP"
CPPFLAGS="-I$TC/include"
# headerpad leaves room for package.sh to rewrite library paths.
# -L as MacPorts adds to every port (configure.ldflags).
LDFLAGS="-L$TC/lib -Wl,-headerpad_max_install_names"
CROSSCFLAGS="-O2 -g $PREFIX_MAP"
# Wine links its PE files in MSVC mode (-target *-windows), so with lld-link,
# which doesn't know MinGW ld's --no-insert-timestamp. -Brepro is lld-link's
# way: the PE timestamp becomes a hash of the output, not the build time.
CROSSLDFLAGS="-Wl,-Brepro"
# A .pdb per Windows-side module, collected by package.sh.
CROSSDEBUG="pdb"

# GStreamer and FFmpeg from GStreamer.framework, as the Portfile's
# +gstreamer variant does.
FW="$TC/Library/Frameworks/GStreamer.framework"
# Its .pc files are relocatable (${pcfiledir}), so our own pkg-config reads
# them; the framework's Commands/pkg-config would honour our
# PKG_CONFIG_LIBDIR above and miss them.
fw_pkg_config() { PKG_CONFIG_LIBDIR="$FW/Versions/1.0/lib/pkgconfig" "$PKG_CONFIG" "$@"; }
FFMPEG_CFLAGS="$(fw_pkg_config --cflags libavutil libavformat libavcodec)"
FFMPEG_LIBS="$(fw_pkg_config --libs libavutil libavformat libavcodec)"
GSTREAMER_CFLAGS="$(fw_pkg_config --cflags gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0)"
GSTREAMER_LIBS="$(fw_pkg_config --libs gstreamer-1.0 gstreamer-video-1.0 gstreamer-audio-1.0 gstreamer-tag-1.0)"

# Functions the SDK has but our minimum macOS doesn't. configure's link test
# can't see availability, so it finds them; Wine then calls them without a
# runtime check, and on an older macOS the weak import is NULL. pipe2 (macOS
# 27) did exactly that: every process crashed when creating its first pipe.
# package.sh fails on any new weak import from libSystem, so a future SDK
# can't add one unnoticed.
NEWER_THAN_TARGET=(
    ac_cv_func_pipe2=no     # macOS 27
    ac_cv_func_dup3=no      # macOS 27
)

# --- Configure -----------------------------------------------------------------
group_start "Configure"
(
    cd "$SRC"
    ./configure \
        --prefix="$PREFIX" \
        --with-mingw="$TC/libexec/llvm-mingw/bin/clang" \
        "${CONFIGURE_ARGS[@]}" \
        CC="$CC" CXX="$CXX" \
        CFLAGS="$CFLAGS" CPPFLAGS="$CPPFLAGS" LDFLAGS="$LDFLAGS" \
        CROSSCFLAGS="$CROSSCFLAGS" CROSSLDFLAGS="$CROSSLDFLAGS" CROSSDEBUG="$CROSSDEBUG" \
        FFMPEG_CFLAGS="$FFMPEG_CFLAGS" FFMPEG_LIBS="$FFMPEG_LIBS" \
        GSTREAMER_CFLAGS="$GSTREAMER_CFLAGS" GSTREAMER_LIBS="$GSTREAMER_LIBS" \
        INSTALL="$SRC/tools/install-sh -c" \
        "${NEWER_THAN_TARGET[@]}" | tee "$W/configure.out"
    # The same fix-up as the Portfile's post-configure: link against the
    # framework's Libraries folder.
    sed -i '' 's|Versions/1.0/lib/pkgconfig/../../lib|Libraries|g' config.status
    ./config.status
)
group_end

# configure already fails when an explicit --with-X can't be satisfied. Its
# remaining notices (features nobody asked for, like X11) are shown here so
# they're easy to review, and recorded for the manifest.
group_start "Configure notices"
grep -E '^configure: ' "$W/configure.out" | tee "$W/configure-notices.txt" || true
group_end

# --- Build ---------------------------------------------------------------------
group_start "Build"
make -C "$SRC" -j"$(sysctl -n hw.ncpu)"
group_end

group_start "Install"
rm -rf "$INSTALL"
make -C "$SRC" install-lib DESTDIR="$INSTALL"
group_end

# What the manifest (build/manifest.py) records about how this was built.
{
    echo "CC=$CC"
    echo "CXX=$CXX"
    echo "CFLAGS=$CFLAGS"
    echo "CPPFLAGS=$CPPFLAGS"
    echo "LDFLAGS=$LDFLAGS"
    echo "CROSSCFLAGS=$CROSSCFLAGS"
    echo "CROSSLDFLAGS=$CROSSLDFLAGS"
    echo "CROSSDEBUG=$CROSSDEBUG"
    echo "MACOSX_DEPLOYMENT_TARGET=$MACOSX_DEPLOYMENT_TARGET"
    echo "SOURCE_DATE_EPOCH=$SOURCE_DATE_EPOCH"
    echo "CONFIGURE_ARGS=${CONFIGURE_ARGS[*]} --with-mingw=<toolchain>/libexec/llvm-mingw/bin/clang"
    echo "MINGW_CC_VERSION=$("$TC/libexec/llvm-mingw/bin/clang" --version | head -1)"
    echo "CC_VERSION=$(/usr/bin/clang --version | head -1)"
    echo "XCODE=$(xcodebuild -version | tr '\n' ' ' | sed 's/ $//')"
    echo "SDK=$(xcrun --show-sdk-version)"
    echo "MACOS=$(sw_vers -productVersion) ($(sw_vers -buildVersion))"
} > "$W/compile-env.txt"

log "Installed into $INSTALL$PREFIX"
