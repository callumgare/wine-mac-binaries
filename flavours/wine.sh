# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: LGPL-2.1-or-later
#
# Flavour "wine": plain WineHQ releases, plus the patches Gcenx's builds of
# the same version carry (listed per version in inputs/wine/<version>.sh).

FLAVOUR_DESCRIPTION="WineHQ's release, with Gcenx's macOS patches"

# Configure options: Gcenx's wine-devel Portfile at fc0301b, with the
# default +gstreamer variant. Paths that depend on the toolchain are added
# by build/compile.sh. Any change here is a deviation from Gcenx's builds and
# must be listed in plan.md ("Deviations from Gcenx's builds").
CONFIGURE_ARGS=(
    --enable-archs=i386,x86_64
    --enable-win64
    --without-alsa
    --without-capi
    --with-coreaudio
    --with-cups
    --without-dbus
    --with-ffmpeg           # +gstreamer variant
    --without-fontconfig
    --with-freetype
    --with-gettext
    --without-gettextpo
    --without-gphoto
    --with-gnutls
    --without-gssapi
    --with-gstreamer        # +gstreamer variant
    --with-inotify
    --without-krb5
    --without-netapi
    --with-opencl
    --without-opengl
    --without-oss
    --with-pcap
    --with-pcsclite
    --with-pthread
    --without-pulse
    --without-sane
    --with-sdl
    --without-udev
    --without-usb
    --without-v4l2
    --with-vulkan
    --without-wayland
    --without-x
    --disable-tests
    --disable-winebth_sys
)

# The source: WineHQ's signed release tarball.
wine_source_url() {
    local v="$1" major
    major="${v%%.*}"
    echo "https://dl.winehq.org/wine/source/$major.x/wine-$v.tar.xz"
}
