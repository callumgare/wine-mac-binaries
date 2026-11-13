#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# package.sh <flavour> <version>
#
# Turns work/<build id>/install into the release tree (layout: plan.md
# section 5), then writes out/<build id>.tar.xz and out/<build id>-debug.tar.xz.
#
#   <build id>/
#     bin/ lib/ lib/wine/ share/wine/   Wine's own install layout
#     lib/*.dylib, lib/GStreamer.framework   bundled libraries
#     BUILD-INFO.json  LICENSES/  README.md
#
# The bundled libraries are found the way Gcenx's builds find them: Wine
# dlopen()s them by leaf name (libgnutls.30.dylib) through the
# @loader_path/../../ rpath of lib/wine/x86_64-unix/*.so.

source "$(dirname "$0")/lib.sh"
require_x86_64 "$@"

[[ $# -eq 2 ]] || die "usage: package.sh <flavour> <version>"
FLAVOUR="$1"; VERSION="$2"
load_build_inputs "$FLAVOUR" "$VERSION"
load_toolchain "$TOOLCHAIN"
export PATH; PATH="$(clean_path)"

W="$WMB_WORK_DIR/$BUILD_ID"
SRC="$W/src"
PKG="$W/pkg"
T="$PKG/$BUILD_ID"                 # the release tree
D="$PKG/$BUILD_ID-debug"           # its debug symbols
INSTALLED="$W/install/opt/wmb/wine"
[[ -d "$INSTALLED/lib/wine" ]] || die "nothing installed at $INSTALLED; run compile.sh first"

rm -rf "$PKG"; mkdir -p "$PKG"
cp -Rp "$INSTALLED" "$T"
# Gcenx's builds don't ship the man pages (`make install-lib` installs them).
rm -rf "$T/share/man"
mkdir -p "$D"

is_macho() { file -b "$1" | grep -q '^Mach-O'; }

# Mach-O files of Wine's own: bin/ and the Unix-side libraries.
wine_machos() {
    find "$T/bin" "$T/lib/wine/x86_64-unix" -type f | while read -r f; do
        is_macho "$f" && echo "$f"
    done
}

# --- Bundle libraries ----------------------------------------------------------
group_start "Bundle libraries"
mkdir -p "$T/lib"

# Libraries Wine dlopen()s: configure records their names as SONAME_* in
# config.h (libgnutls.30.dylib, libSDL2-2.0.0.dylib, ...).
dlopened=()
while read -r name; do
    if [[ -e "$TC/lib/$name" ]]; then
        dlopened+=("$TC/lib/$name")
    else
        log "not bundled (not in the toolchain, so the system's is used): $name"
    fi
done < <(sed -n 's/^#define SONAME_[A-Z0-9_]* "\(.*\)"$/\1/p' "$SRC/include/config.h" | sort -u)

# Libraries a Mach-O links against from the toolchain.
toolchain_deps() {
    otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -F "$TC/lib/" || true
}

# Walk the closure. Each library is copied under the name it's referenced
# by (resolving symlinks), so only names something actually uses ship.
# (macOS's bash 3.2 has no associative arrays: the copied file is the
# "seen" marker.)
: > "$W/bundled-libs.txt"
bundle() {
    local lib="$1" name dep
    name="$(basename "$lib")"
    [[ -e "$T/lib/$name" ]] && return
    cp -L "$lib" "$T/lib/$name"
    chmod 0755 "$T/lib/$name"
    echo "$name $lib" >> "$W/bundled-libs.txt"
    for dep in $(toolchain_deps "$lib"); do bundle "$dep"; done
}
for lib in ${dlopened[@]+"${dlopened[@]}"}; do bundle "$lib"; done
for f in $(wine_machos); do
    for dep in $(toolchain_deps "$f"); do bundle "$dep"; done
done
sort -o "$W/bundled-libs.txt" "$W/bundled-libs.txt"
log "Bundled $(wc -l < "$W/bundled-libs.txt" | tr -d ' ') libraries"

# Rewrite every reference into the toolchain to a relative one.
while read -r name _; do
    f="$T/lib/$name"
    install_name_tool -id "@rpath/$name" "$f" 2>/dev/null
    while read -r dep; do
        install_name_tool -change "$dep" "@loader_path/$(basename "$dep")" "$f" 2>/dev/null
    done < <(toolchain_deps "$f")
done < "$W/bundled-libs.txt"
while read -r f; do
    while read -r dep; do
        install_name_tool -change "$dep" "@rpath/$(basename "$dep")" "$f" 2>/dev/null
    done < <(toolchain_deps "$f")
done < <(wine_machos)

# MoltenVK: nothing links it. The Vulkan loader (libvulkan.1.dylib, which
# Wine dlopen()s) finds it through this manifest, as in Gcenx's builds:
# share/vulkan/icd.d/MoltenVK_icd.json -> ../../../lib/libMoltenVK.dylib
bundle "$TC/lib/libMoltenVK.dylib"
install_name_tool -id "@rpath/libMoltenVK.dylib" "$T/lib/libMoltenVK.dylib" 2>/dev/null
mkdir -p "$T/share/vulkan/icd.d"
cp "$TC/share/vulkan/icd.d/MoltenVK_icd.json" "$T/share/vulkan/icd.d/"

# GStreamer.framework, as Gcenx ships it: lib/GStreamer.framework.
cp -Rp "$TC/Library/Frameworks/GStreamer.framework" "$T/lib/"
group_end

# --- Run paths -----------------------------------------------------------------
group_start "Run paths"
rpaths() { otool -l "$1" | awk '/cmd LC_RPATH/{getline; getline; print $2}'; }
add_rpath() { rpaths "$1" | grep -qxF "$2" || install_name_tool -add_rpath "$2" "$1" 2>/dev/null; }

# Drop absolute run paths (the toolchain, /Library/Frameworks) from Wine's
# files and the bundled libraries: the build must only ever load what it
# ships. Deviation from Gcenx, whose winegstreamer.so and winedmo.so also
# search /Library/Frameworks/GStreamer.framework first.
while read -r f; do
    while read -r rp; do
        [[ "$rp" == /* ]] && install_name_tool -delete_rpath "$rp" "$f" 2>/dev/null
    done < <(rpaths "$f")
    case "$f" in
        # Only the programs that link a bundled library (wineserver:
        # libinotify) need a way to find lib/; Gcenx's wine has no rpath.
        "$T/bin/"*)
            if otool -L "$f" | grep -v ':$' | awk '{print $1}' | grep -q '^@rpath/'; then
                add_rpath "$f" "@loader_path/../lib"
            fi ;;
        # These find GStreamer's and FFmpeg's libraries in the framework.
        */x86_64-unix/winegstreamer.so|*/x86_64-unix/winedmo.so)
            add_rpath "$f" "@loader_path/../../GStreamer.framework/Libraries" ;;
        # The rest dlopen() bundled libraries by leaf name
        # (libgnutls.30.dylib), which dyld looks up through the caller's
        # rpaths: lib/wine/x86_64-unix/../../ is lib/. As Gcenx's builds.
        */x86_64-unix/*.so)
            add_rpath "$f" "@loader_path/../../" ;;
    esac
done < <(wine_machos; sed "s|^\([^ ]*\) .*|$T/lib/\1|" "$W/bundled-libs.txt")
group_end

# --- Debug symbols -------------------------------------------------------------
# Mac side: a .dSYM per Mach-O (matched by LC_UUID), then strip the debug
# map. Windows side: the .pdb files the build wrote (CROSSDEBUG=pdb).
group_start "Debug symbols"
while read -r f; do
    rel="${f#"$T/"}"
    # A few Unix libraries compile to nothing on macOS (wined3d.so is all
    # behind SONAME_LIBVA, netapi32.so behind SONAME_LIBNETAPI): no debug
    # map, so nothing to split off.
    # (grep -c, not -q: -q stops reading early, nm gets SIGPIPE, and
    # pipefail would make every file look like this.)
    if [[ "$(nm -ap "$f" 2>/dev/null | grep -c ' OSO ' || true)" -eq 0 ]]; then
        log "no debug info (no code compiled in on macOS): $rel"
        continue
    fi
    mkdir -p "$D/$(dirname "$rel")"
    dsymutil --out "$D/$rel.dSYM" "$f"
    strip -S "$f"
done < <(wine_machos)

(cd "$SRC" && find . -name '*.pdb' -path '*-windows/*') | while read -r p; do
    arch="$(basename "$(dirname "$p")")"     # i386-windows, x86_64-windows
    mkdir -p "$D/lib/wine/$arch"
    cp "$SRC/$p" "$D/lib/wine/$arch/"
done
group_end

# --- Gecko and Mono ------------------------------------------------------------
group_start "Gecko $GECKO_VERSION, Mono $MONO_VERSION"
mkdir -p "$T/share/wine/gecko" "$T/share/wine/mono"
tar -xJf "$(fetch "$GECKO_X86_URL" "$GECKO_X86_SHA256")" -C "$T/share/wine/gecko"
tar -xJf "$(fetch "$GECKO_X86_64_URL" "$GECKO_X86_64_SHA256")" -C "$T/share/wine/gecko"
tar -xJf "$(fetch "$MONO_URL" "$MONO_SHA256")" -C "$T/share/wine/mono"
group_end

# --- Sign ----------------------------------------------------------------------
group_start "Ad hoc signing"
find "$T/bin" "$T/lib" -path "$T/lib/GStreamer.framework" -prune -o -type f -print | while read -r f; do
    is_macho "$f" && codesign --force --sign - "$f" 2>&1 | grep -v 'replacing existing signature' || true
done
codesign --force --deep --sign - "$T/lib/GStreamer.framework"
group_end

# --- Checks --------------------------------------------------------------------
# Nothing may point into the toolchain or the build machine.
group_start "Checks"
bad=0
while read -r f; do
    # (A universal file, like MoltenVK, has a "<file> (architecture ...):"
    # header per architecture; those lines aren't references.)
    if otool -L "$f" 2>/dev/null | grep -v ':$' | awk '{print $1}' | grep -E "^($TC|/opt/|/usr/local/|/Users/)"; then
        warn "$f links outside the build"; bad=1
    fi
    if rpaths "$f" | grep -E '^/'; then
        warn "$f has an absolute run path"; bad=1
    fi
done < <(find "$T/bin" "$T/lib" -path "$T/lib/GStreamer.framework" -prune -o -type f -print | while read -r f; do is_macho "$f" && echo "$f"; done)
[[ $bad -eq 0 ]] || die "the build references files outside itself"

# Wine's own files may weak-import from libSystem only what Wine checks for
# at run time (the same list as Gcenx's 11.21). Anything else is a function
# newer than the minimum macOS that configure detected anyway (see
# NEWER_THAN_TARGET in compile.sh): on an older macOS it's NULL.
WEAK_OK='^_(os_sync_wait_on_address|os_sync_wait_on_address_with_timeout|os_sync_wake_by_address_any|pthread_cpu_number_np|_availability_version_check)$'
while read -r f; do
    dyld_info -imports "$f" | grep 'weak-import.*(from libSystem)' |
        grep -o -E '_[A-Za-z0-9_$]+ \[weak-import\]' | awk '{print $1}' |
        grep -v -E "$WEAK_OK" | sed "s|^|${f#"$T/"}: unguarded weak import |" ||
        true    # (grep finding nothing is the good case)
done < <(wine_machos) > "$W/weak-imports.txt"
if [[ -s "$W/weak-imports.txt" ]]; then
    cat "$W/weak-imports.txt"
    die "Wine uses functions newer than macOS $DEPLOYMENT_TARGET (add them to NEWER_THAN_TARGET in compile.sh)"
fi

# The bundled MacPorts libraries are built against the $DEPLOYMENT_TARGET SDK
# (PORTS_SDK in the toolchain), so they shouldn't weak-import anything from
# libSystem but clang's own availability check. (With a newer SDK, libidn2
# weak-imported macOS 15.4's strchrnul.) MoltenVK and GStreamer are
# upstream's prebuilt binaries and aren't checked.
LIB_WEAK_OK='^__availability_version_check$'
while read -r f; do
    dyld_info -imports "$f" | grep 'weak-import.*(from libSystem)' |
        grep -o -E '_[A-Za-z0-9_$]+ \[weak-import\]' | awk '{print $1}' |
        grep -v -E "$LIB_WEAK_OK" | sed "s|^|${f#"$T/"}: unguarded weak import |" ||
        true
done < <(find "$T/lib" -maxdepth 1 -type f -name '*.dylib' ! -name 'libMoltenVK.dylib') > "$W/lib-weak-imports.txt"
if [[ -s "$W/lib-weak-imports.txt" ]]; then
    cat "$W/lib-weak-imports.txt"
    die "bundled libraries use functions newer than macOS $DEPLOYMENT_TARGET (was the toolchain built against PORTS_SDK?)"
fi
group_end

log "Release tree at $T"
