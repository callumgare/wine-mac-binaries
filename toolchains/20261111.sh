# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: LGPL-2.1-or-later
# Toolchain 20261111: everything a build needs besides macOS and Xcode.
#
# Installed at /opt/wmb/toolchains/20261111 by build/toolchain.sh, and
# published to ghcr.io/callumgare/wine-mac-binaries/toolchain:20261111 by
# run https://github.com/callumgare/wine-mac-builds/actions/runs/43566153585.
#
# Built inside: ghcr.io/cirruslabs/macos-tahoe-xcode:27.2 (see TART_IMAGE).

# The macOS + Xcode this toolchain is built and used with. A digest, not a
# tag, so the same image comes back years later.
TART_IMAGE="ghcr.io/cirruslabs/macos-tahoe-xcode@sha256:f8315a2f627daf64ab2c4e11d29a4d267953902a16151ee28fcdd7185927c317"
XCODE_VERSION="27.2"

# The published archive: an OCI artifact on GitHub's container registry,
# pushed by the toolchain workflow (tag 20261111). Builds without a local
# archive download its layer by this sha256 (from the artifact's
# SHA256SUMS). Under the repo's old name: the run that pushed it started
# before the rename, and its provenance verifies with
#   gh attestation verify <file> --repo callumgare/wine-mac-binaries
TOOLCHAIN_ARCHIVE_REPO="callumgare/wine-mac-binaries/toolchain"
TOOLCHAIN_ARCHIVE_SHA256="96f5094b004511d2e633a77d52fa5c010682abbcf47e0b9ecf2b6d725fc3cdd0"

# Everything shipped inside a build carries this minimum macOS, as Gcenx's
# Wine binaries do.
DEPLOYMENT_TARGET="10.15"

# The SDK every MacPorts port is built against: Apple's 10.15 SDK, matching
# DEPLOYMENT_TARGET, so configure scripts can't find (and libraries can't
# weak-link) functions newer than the minimum macOS. With Xcode 27.2's SDK,
# gettext picked up macOS 27's pipe2 and its xgettext crashed on the macOS 26
# build VM; with the 26.5 SDK, libidn2 weak-linked macOS 15.4's strchrnul.
# Gcenx builds his libraries the same way (against 10.14); this is the
# archive his MacOSX10.15.sdk port downloads, re-hosted by him. Only used
# while building; never shipped, nor put in the toolchain archive.
# (Wine itself is built with Xcode's SDK, as Gcenx's is; see compile.sh.)
PORTS_SDK_VERSION="10.15"
PORTS_SDK_URL="https://github.com/Gcenx/macos-sdk/releases/download/10.15/MacOSX10.15.tar.bz2"
PORTS_SDK_SHA256="bb548125ebf5cf4ae6c80d226f40ad39e155564ca78bc00554a2e84074d0180e"

# --- MacPorts: builds the shipped libraries from source ---------------------
MACPORTS_VERSION="2.12.7"
MACPORTS_URL="https://github.com/macports/macports-base/releases/download/v2.12.7/MacPorts-2.12.7.tar.bz2"
MACPORTS_SHA256="6a3730de846bb78e3fb4ced2ed8d13f777e6aca2ab2f59cade9ca0d549ccc4ba"

# The ports tree, pinned by commit (2026-11-11).
MACPORTS_PORTS_REPO="https://github.com/macports/macports-ports.git"
MACPORTS_PORTS_COMMIT="fcbcf6329cd65dca854704b25354d045603e4864"

# Gcenx's overlay, only for ports the main tree doesn't have (libinotify).
# Pinned at the 11.21 update.
GCENX_PORTS_REPO="https://github.com/Gcenx/macports-wine.git"
GCENX_PORTS_COMMIT="fc0301b4896daf29bdf7140d7c67ed01f12aaacd"
# Only these ports are taken from the overlay; everything else comes from the
# main tree, so the overlay can't silently replace a main-tree port.
GCENX_PORTS_USED=(devel/libinotify)

# Ports installed. The libraries match Gcenx's wine-devel Portfile's
# depends_lib; the rest are its depends_build.
MACPORTS_PORTS=(
    # shipped (depends_lib)
    gnutls
    freetype
    gettext-runtime
    libinotify
    libpcap
    libsdl2
    vulkan-loader
    # build only (depends_build)
    bison
    flex
    pkgconfig
    gettext
)

# --- Prebuilt upstream releases ----------------------------------------------
# Build-only: the compiler for Wine's Windows-side DLLs. The exact file
# Gcenx's cross/llvm-mingw port unpacks.
LLVM_MINGW_VERSION="20261020"
LLVM_MINGW_URL="https://github.com/mstorsjo/llvm-mingw/releases/download/20261020/llvm-mingw-20261020-ucrt-macos-universal.tar.xz"
LLVM_MINGW_SHA256="e9c13e4ede38e715003ffc674d4d00a1088df8235439d1f0c16188ff0704c17e"

# Shipped. Gcenx's 11.21 carries Khronos's prebuilt v1.4.0 (LC_UUID
# F64EE2CD-C80D-3719-88DD-737C309046BB matches), not the newer 1.4.2.
MOLTENVK_VERSION="1.4.0"
MOLTENVK_URL="https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.0/MoltenVK-macos.tar"
MOLTENVK_SHA256="f4feaf6a4988352de8e6d49874ccc1cd6a45021e3cb476e8531bef7ecc73e93a"

# Shipped. The framework Gcenx's gstreamer.framework port installs: an x86_64
# build published by Sikarugir-App, not freedesktop.org's official package.
# Open question, plan.md section 2.
GSTREAMER_VERSION="1.28.1"
GSTREAMER_URL="https://github.com/Sikarugir-App/gstreamer/releases/download/1.28.1/gstreamer.framework-1.0-1.28.1-x86_64.tar.xz"
GSTREAMER_SHA256="26dbeba8283e5a9f0c9429d059cb96642b6aaf245e5a694da9a3799e2b7ada0a"
