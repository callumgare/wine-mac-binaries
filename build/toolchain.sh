#!/bin/bash
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# toolchain.sh <id> [--archive]
#
# Assembles toolchain <id> (defined in toolchains/<id>.sh) at
# /opt/wmb/toolchains/<id>: MacPorts built from source at the 10.15
# deployment target, the shipped libraries Gcenx's builds carry, and the
# prebuilt llvm-mingw, MoltenVK and GStreamer.framework.
#
# With --archive, also writes out/toolchain-<id>-macos-x86_64.tar.xz and a
# tarball of every source file MacPorts downloaded.
#
# Meant to run in a fresh VM from the toolchain's TART_IMAGE. It needs sudo
# only to create /opt/wmb.

source "$(dirname "$0")/lib.sh"
# Everything runs as x86_64 under Rosetta, MacPorts included, so every
# configure script it starts sees an x86_64 host. (Run natively, MacPorts is
# arm64 and so are the configure scripts it starts: they detect an ARM host
# and, like nettle's, pick ARM assembly for an x86_64 build.) Xcode's clang
# targets arm64 by default even under Rosetta, so MacPorts itself is built
# with -arch x86_64, and checked.
require_x86_64 "$@"

[[ $# -ge 1 ]] || die "usage: toolchain.sh <id> [--archive]"
ID="$1"; shift
ARCHIVE=0
[[ "${1:-}" == "--archive" ]] && ARCHIVE=1

load_toolchain "$ID"

# One compiler for everything: Xcode's.
#
# MacPorts builds ports with the Command Line Tools (DEVELOPER_DIR=
# /Library/Developer/CommandLineTools) unless a port sets use_xcode, while
# Wine is built with Xcode's clang. And the Command Line Tools 27.0 in the
# pinned image ship a libxcrun without an x86_64 slice, so every x86_64
# build tool MacPorts makes (cmake, ...) can't run clang at all. MacPorts
# has no global setting for this (use_xcode=yes on the command line doesn't
# reach dependencies), so after installing MacPorts we change two lines of it:
#
#   - configure_get_developer_dir always returns Xcode's directory;
#   - configure_get_sdkroot always returns $PORTS_SDK (below), the SDK
#     pinned in the toolchain definition. MacPorts would otherwise pick the
#     CLT's SDK for the running macOS (26.x), and macports.conf can't set
#     the path: macosx_sdk_path there is ignored, it's only for portindex.
#
# The port build logs are checked afterwards.
patch_macports_use_xcode() {
    local f="$TC/libexec/macports/lib/port1.0/portconfigure.tcl"
    grep -q 'wine-mac-binaries: always use Xcode' "$f" ||
        sed -i '' 's/^    if {\[tbool use_xcode\]} {$/    if {1 || [tbool use_xcode]} {  ;# wine-mac-binaries: always use Xcode/' "$f"
    grep -q 'wine-mac-binaries: always our SDK' "$f" ||
        sed -i '' "/^proc portconfigure::configure_get_sdkroot {sdk_version} {\$/a\\
\\    return {$PORTS_SDK}  ;# wine-mac-binaries: always our SDK
" "$f"
    grep -q 'wine-mac-binaries: always use Xcode' "$f" &&
        grep -qF "return {$PORTS_SDK}  ;# wine-mac-binaries: always our SDK" "$f" ||
        die "couldn't patch $f (MacPorts changed?)"
}

export PATH; PATH="$(clean_path)"
export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"
# The preprocessor, for x86_64. Xcode's clang targets arm64 even under
# Rosetta, and MacPorts passes -arch only in CFLAGS/CXXFLAGS (CPPFLAGS has
# none, and some Portfiles replace it), so configure's checks with `$CC -E`
# ran for arm64. The 10.15 SDK has no arm64, so they failed and configure
# fell back to /lib/cpp; with a newer SDK they silently answered for the
# wrong arch. macports.conf's extra_env (below) passes these through.
export CPP="/usr/bin/clang -E -arch x86_64" CXXCPP="/usr/bin/clang++ -E -arch x86_64"
JOBS="$(sysctl -n hw.ncpu)"

if [[ ! -w "$WMB_TOOLCHAINS_DIR" ]]; then
    sudo mkdir -p "$WMB_TOOLCHAINS_DIR"
    sudo chown "$(id -u):$(id -g)" "$WMB_TOOLCHAINS_DIR"
fi
ARCHIVE_FILE="$WMB_OUT_DIR/toolchain-$ID-macos-x86_64.tar.xz"

if [[ -f "$TC/.complete" ]]; then
    log "Toolchain $ID is already at $TC"
elif [[ -f "$ARCHIVE_FILE" && $ARCHIVE -eq 0 ]]; then
    # TODO: once published, also download it from its release, pinned by
    # sha256 in toolchains/<id>.sh.
    group_start "Installing toolchain $ID from $ARCHIVE_FILE"
    [[ -e "$TC" ]] && die "$TC exists but is incomplete; delete it and run again"
    tar -xJf "$ARCHIVE_FILE" -C "$WMB_TOOLCHAINS_DIR"
    [[ -f "$TC/.complete" ]] || die "$ARCHIVE_FILE didn't contain a complete toolchain"
    group_end
else
    # An unfinished toolchain is resumed: each stage below skips itself if
    # it already completed. (Only within one machine or VM; a published
    # toolchain is always built in one go from a fresh VM.)
    mkdir -p "$TC"
    SRC="$WMB_WORK_DIR/toolchain-$ID"
    mkdir -p "$SRC"

    # --- MacPorts base ------------------------------------------------------
    if [[ ! -x "$TC/bin/port" ]]; then
    group_start "MacPorts $MACPORTS_VERSION"
    rm -rf "$SRC/MacPorts-$MACPORTS_VERSION"
    tar -xjf "$(fetch "$MACPORTS_URL" "$MACPORTS_SHA256")" -C "$SRC"
    (
        cd "$SRC/MacPorts-$MACPORTS_VERSION"
        ./configure --prefix="$TC" \
            CC="/usr/bin/clang -arch x86_64" OBJC="/usr/bin/clang -arch x86_64" \
            --with-applications-dir="$TC/Applications" \
            --with-frameworks-dir="$TC/Library/Frameworks" \
            --with-no-root-privileges \
            --without-startupitems
        make -j"$JOBS"
        # MacPorts refuses to run under Rosetta unless build_arch is x86_64,
        # and `make install` runs MacPorts before our settings are added
        # below. So put build_arch in the config file it installs.
        printf '\nbuild_arch                  x86_64\n' >> doc/macports.conf
        make install
    )
    group_end
    fi

    if [[ "$(lipo -archs "$TC/libexec/macports/bin/tclsh8.6")" != x86_64 ]]; then
        die "MacPorts' tclsh isn't x86_64; its configure scripts would see an ARM host"
    fi

    # --- The SDK the ports are built against ---------------------------------
    # Kept in the work directory, not $TC: it's Apple's, so it must not end
    # up in the toolchain archive.
    PORTS_SDK="$SRC/sdk/MacOSX$PORTS_SDK_VERSION.sdk"
    if [[ ! -f "$PORTS_SDK/.complete" ]]; then
    group_start "macOS $PORTS_SDK_VERSION SDK for the ports"
    rm -rf "$SRC/sdk"; mkdir -p "$SRC/sdk"
    tar -xjf "$(fetch "$PORTS_SDK_URL" "$PORTS_SDK_SHA256")" -C "$SRC/sdk"
    [[ -f "$PORTS_SDK/SDKSettings.json" ]] || die "the SDK archive didn't contain MacOSX$PORTS_SDK_VERSION.sdk"
    # Xcode's clang no longer carries libc++'s headers itself; they're in
    # Xcode's SDK, and the old SDK has none. Use Xcode's: they're the ones
    # Wine's C++-using dependencies get today, and they mark what each
    # macOS version's libc++ lacks, so the deployment target still guards
    # them. (They warn that 10.15 is no longer supported by libc++.)
    xcode_sdk="$(xcrun --sdk macosx --show-sdk-path)"
    [[ -d "$xcode_sdk/usr/include/c++/v1" ]] || die "no libc++ headers in $xcode_sdk"
    mkdir -p "$PORTS_SDK/usr/include/c++"
    cp -R "$xcode_sdk/usr/include/c++/v1" "$PORTS_SDK/usr/include/c++/"
    touch "$PORTS_SDK/.complete"
    group_end
    fi
    patch_macports_use_xcode

    # --- Ports trees, pinned by commit; never `port sync` -------------------
    PORTS="$TC/var/wmb/ports"
    if [[ ! -f "$PORTS/.indexed" ]]; then
    group_start "Ports trees"
    git_checkout "$MACPORTS_PORTS_REPO" "$MACPORTS_PORTS_COMMIT" "$PORTS/macports-ports"
    git_checkout "$GCENX_PORTS_REPO" "$GCENX_PORTS_COMMIT" "$SRC/gcenx-ports"
    rm -rf "$PORTS/overlay"; mkdir -p "$PORTS/overlay"
    for p in "${GCENX_PORTS_USED[@]}"; do
        mkdir -p "$PORTS/overlay/$(dirname "$p")"
        cp -R "$SRC/gcenx-ports/$p" "$PORTS/overlay/$p"
    done
    # The overlay has no PortGroups of its own; use the main tree's.
    ln -sfn "$PORTS/macports-ports/_resources" "$PORTS/overlay/_resources"
    cat > "$TC/etc/macports/sources.conf" <<EOF
file://$PORTS/overlay
file://$PORTS/macports-ports [default]
EOF
    # Indexing the main tree takes most of an hour under Rosetta, and gives
    # the same result for the same tree, MacPorts, image and prefix. So the
    # index is cached under that key. (portindex's own incremental mode
    # doesn't help: a fresh checkout makes every Portfile look new.)
    index_key="$(printf '%s\n' "$MACPORTS_VERSION" "$MACPORTS_PORTS_COMMIT" "$TART_IMAGE" "$TC" |
        shasum -a 256 | cut -c1-16)"
    index_cache="$WMB_CACHE_DIR/portindex/$index_key"
    # portindex prints parse failures but still exits 0; treat them as fatal.
    for tree in overlay macports-ports; do
        if [[ "$tree" == macports-ports && -f "$index_cache/PortIndex.quick" ]]; then
            log "Using cached index of $tree ($index_key)"
            cp "$index_cache"/PortIndex* "$PORTS/$tree/"
            continue
        fi
        log "Indexing $tree (log: $SRC/portindex-$tree.log)"
        (cd "$PORTS/$tree" && "$TC/bin/portindex") > "$SRC/portindex-$tree.log" 2>&1 ||
            die "portindex failed for $tree (see $SRC/portindex-$tree.log)"
        tr '\r' '\n' < "$SRC/portindex-$tree.log" | grep -a -E '^(Total|Failed)' || true
        if grep -a -q 'Failed to parse' "$SRC/portindex-$tree.log"; then
            [[ "$tree" == overlay ]] && die "portindex couldn't parse an overlay port (see above)"
            warn "some main-tree ports didn't parse; fine unless one we install is among them"
        fi
        if [[ "$tree" == macports-ports ]]; then
            mkdir -p "$index_cache.tmp"
            cp "$PORTS/$tree"/PortIndex* "$index_cache.tmp/"
            rm -rf "$index_cache"; mv "$index_cache.tmp" "$index_cache"
        fi
    done
    cat >> "$TC/etc/macports/macports.conf" <<EOF

# --- wine-mac-binaries (build/toolchain.sh) ---
# Build everything from source for the deployment target below. There are no
# prebuilt archives for this prefix anyway.
buildfromsource             always
macosx_deployment_target    $DEPLOYMENT_TARGET
build_arch                  x86_64
startupitem_install         no
# The version of \$PORTS_SDK, which the patch above makes MacPorts use.
# (Portfiles test this version.)
macosx_sdk_version          $PORTS_SDK_VERSION
# CPP and CXXCPP, set above.
extra_env                   CPP CXXCPP
# Keep every port's build log (checked below, and part of the record).
keeplogs                    yes
EOF
    touch "$PORTS/.indexed"
    group_end
    fi

    # --- Libraries and build tools ------------------------------------------
    group_start "Ports: ${MACPORTS_PORTS[*]}"
    if ! "$TC/bin/port" -N install "${MACPORTS_PORTS[@]}"; then
        # Print the failed port's log, since vm.sh deletes the VM (and the
        # log with it) on failure. That's the log with a "Failed to <phase>"
        # error; the ports depending on it only say "Processing ... failed".
        grep -l -E '^:error:[a-z]+ Failed to ' "$TC"/var/macports/logs/*/*/main.log 2>/dev/null |
        while read -r failed_log; do
            log "last 120 lines of $failed_log (debug lines dropped):"
            grep -v '^:debug:' "$failed_log" | tail -n 120 | cut -c1-600 >&2 || true
            # A configure failure's reason is usually only in config.log.
            if grep -q '^:error:configure ' "$failed_log"; then
                cl="$(grep -o -E -m 1 'consult [^ ]*/config\.log' "$failed_log" | cut -d' ' -f2)"
                if [[ -n "$cl" && -f "$cl" ]]; then
                    log "errors in $cl:"
                    grep -n -E 'error|Error' "$cl" | tail -n 40 | cut -c1-400 >&2 || true
                fi
            fi
        done
        die "MacPorts failed to install the ports above"
    fi
    # Every port, dependencies included, must have used Xcode's compiler and
    # $PORTS_SDK. (Prints what it found: on failure vm.sh deletes the VM,
    # logs and all, so the reason must be in the build's own output.)
    if grep -H -o -E "DEVELOPER_DIR='/Library/Developer/CommandLineTools[^']*'|SDKROOT='[^']*'" \
            "$TC"/var/macports/logs/*/*/main.log 2>/dev/null |
        grep -v -F "SDKROOT='$PORTS_SDK'" |
        sed -E 's|^[^:]*/logs/[^/]*/([^/]*)/main.log:|\1: |' | sort -u | head -20; then
        die "the ports above weren't built with Xcode's compiler and $PORTS_SDK"
    fi
    grep -q -F "SDKROOT='$PORTS_SDK'" "$TC"/var/macports/logs/*/*/main.log ||
        die "no port log shows SDKROOT='$PORTS_SDK'; has MacPorts' log format changed?"
    # ...and their configure scripts must have preprocessed with clang.
    if grep -H -m 1 -E 'checking how to run the C(\+\+)? preprocessor\.\.\. /lib/cpp' \
            "$TC"/var/macports/logs/*/*/main.log 2>/dev/null |
        sed -E 's|^[^:]*/logs/[^/]*/([^/]*)/main.log:|\1: |'; then
        die "configure fell back to /lib/cpp in the ports above (clang -E failed; see config.log)"
    fi
    "$TC/bin/port" -q installed > "$SRC/ports-installed.txt"
    group_end

    # MacPorts doesn't install licence texts, and a build must ship one for
    # every library it bundles. Re-extract each port's (already downloaded)
    # source and keep its top-level licence files.
    group_start "Licence texts"
    for port in $("$TC/bin/port" -q installed | awk '{print $1}' | sort -u); do
        "$TC/bin/port" -q extract "$port" >/dev/null
        wd="$("$TC/bin/port" -q work "$port")"
        dest="$TC/share/wmb/licenses/$port"
        mkdir -p "$dest"
        # The extracted source is usually one folder down from the work dir.
        find "$wd" -maxdepth 2 -type f \( -iname 'COPYING*' -o -iname 'LICEN[CS]E*' -o -iname 'COPYRIGHT*' -o -iname 'NOTICE*' \) \
            -exec cp {} "$dest/" \;
        "$TC/bin/port" -q info --license "$port" | sed 's/^license: //' > "$dest/MACPORTS-LICENSE-FIELD"
        "$TC/bin/port" -q clean --work "$port" >/dev/null
        if [[ -z "$(ls "$dest" | grep -v MACPORTS-LICENSE-FIELD)" ]]; then
            warn "no licence file found in $port's source"
        fi
    done
    group_end

    # --- Prebuilt upstream releases -----------------------------------------
    group_start "llvm-mingw $LLVM_MINGW_VERSION"
    mkdir -p "$TC/libexec/llvm-mingw"
    tar -xJf "$(fetch "$LLVM_MINGW_URL" "$LLVM_MINGW_SHA256")" -C "$TC/libexec/llvm-mingw" --strip-components 1
    group_end

    group_start "MoltenVK $MOLTENVK_VERSION"
    tar -xf "$(fetch "$MOLTENVK_URL" "$MOLTENVK_SHA256")" -C "$SRC"
    install -m 0755 "$SRC/MoltenVK/MoltenVK/dynamic/dylib/macOS/libMoltenVK.dylib" "$TC/lib/libMoltenVK.dylib"
    mkdir -p "$TC/share/vulkan/icd.d"
    sed 's|"library_path" *: *"[^"]*"|"library_path" : "../../../lib/libMoltenVK.dylib"|' \
        "$SRC/MoltenVK/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json" > "$TC/share/vulkan/icd.d/MoltenVK_icd.json"
    mkdir -p "$TC/share/wmb/licenses/MoltenVK"
    cp "$SRC/MoltenVK/LICENSE" "$TC/share/wmb/licenses/MoltenVK/"
    group_end

    group_start "GStreamer.framework $GSTREAMER_VERSION"
    mkdir -p "$TC/Library/Frameworks"
    tar -xJf "$(fetch "$GSTREAMER_URL" "$GSTREAMER_SHA256")" -C "$SRC"
    rm -f "$SRC/GStreamer.framework/.gitignore"
    mv "$SRC/GStreamer.framework" "$TC/Library/Frameworks/"
    group_end

    # --- What's in it --------------------------------------------------------
    mkdir -p "$TC/share/wmb"
    {
        echo "toolchain: $ID"
        echo "tart_image: $TART_IMAGE"
        echo "xcode: $(xcodebuild -version | tr '\n' ' ')"
        echo "clang: $(/usr/bin/clang --version | head -1)"
        echo "macos: $(sw_vers -productVersion) ($(sw_vers -buildVersion))"
        echo "deployment_target: $DEPLOYMENT_TARGET"
        echo "macports: $MACPORTS_VERSION (patched: always build with Xcode and the ports SDK, see build/toolchain.sh)"
        echo "ports_sdk: MacOSX$PORTS_SDK_VERSION.sdk $PORTS_SDK_SHA256 $PORTS_SDK_URL (plus libc++ headers from Xcode's SDK)"
        echo "macports_ports_commit: $MACPORTS_PORTS_COMMIT"
        echo "gcenx_ports_commit: $GCENX_PORTS_COMMIT (${GCENX_PORTS_USED[*]})"
        echo "llvm_mingw: $LLVM_MINGW_VERSION $LLVM_MINGW_SHA256"
        echo "moltenvk: $MOLTENVK_VERSION $MOLTENVK_SHA256"
        echo "gstreamer: $GSTREAMER_VERSION $GSTREAMER_SHA256"
        echo "ports:"
        sed 's/^/  /' "$SRC/ports-installed.txt"
    } > "$TC/share/wmb/toolchain.txt"
    touch "$TC/.complete"
    log "Toolchain $ID ready at $TC"
fi

if [[ $ARCHIVE -eq 1 ]]; then
    NAME="toolchain-$ID-macos-x86_64"
    group_start "Archiving $NAME"
    # The archive unpacks to the toolchain's own fixed path.
    STAGE="$WMB_WORK_DIR/archive-$ID"
    rm -rf "$STAGE"; mkdir -p "$STAGE"
    # Downloaded sources go in their own archive (they're the corresponding
    # source for the libraries we ship, section 6 of plan.md).
    DIST="$TC/var/macports/distfiles"
    EPOCH="$(date -j -u -f '%Y%m%d%H%M%S' "${ID}000000" +%s)"
    cp -Rp "$TC" "$STAGE/$ID"
    rm -rf "$STAGE/$ID/var/macports/distfiles" "$STAGE/$ID/var/macports/build" "$STAGE/$ID/var/macports/logs"
    deterministic_tar "$STAGE" "$ID" "$WMB_OUT_DIR/$NAME.tar.xz" "$EPOCH"
    if [[ -d "$DIST" ]]; then
        rm -rf "$STAGE/$NAME-sources"
        cp -Rp "$DIST" "$STAGE/$NAME-sources"
        deterministic_tar "$STAGE" "$NAME-sources" "$WMB_OUT_DIR/$NAME-sources.tar.xz" "$EPOCH"
    fi
    (cd "$WMB_OUT_DIR" && shasum -a 256 "$NAME".tar.xz "$NAME"-sources.tar* 2>/dev/null)
    group_end
fi
