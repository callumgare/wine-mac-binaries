# shellcheck shell=bash disable=SC2034
# SPDX-License-Identifier: LGPL-2.1-or-later
# Pinned inputs for wine 11.21. Written by tools/pin; review changes like code.

WINE_VERSION="11.21"
BUILD_REVISION=1
TOOLCHAIN="20261111"

WINE_URL="https://dl.winehq.org/wine/source/11.x/wine-11.21.tar.xz"
WINE_SHA256="5a40f593432d81fd3a1646db503f21ce42b8894d6d80c34c3a48b886edc54e3d"
# The tarball's .sign verified with this key when pinned (2026-11-11):
WINE_SIGNING_KEY="DA23579A74D4AD9AF9D3F945CEFAC8EAAF17519D"   # Alexandre Julliard
# Release date, used as SOURCE_DATE_EPOCH (signature creation time).
WINE_RELEASE_EPOCH=1793393615

# Add-ons: the versions dlls/appwiz.cpl/addons.c names, as the tarballs
# Gcenx extracts into share/wine.
GECKO_VERSION="2.47.4"
GECKO_X86_URL="https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86.tar.xz"
GECKO_X86_SHA256="2cfc8d5c948602e21eff8a78613e1826f2d033df9672cace87fed56e8310afb6"
GECKO_X86_64_URL="https://dl.winehq.org/wine/wine-gecko/2.47.4/wine-gecko-2.47.4-x86_64.tar.xz"
GECKO_X86_64_SHA256="fd88fc7e537d058d7a8abf0c1ebc90c574892a466de86706a26d254710a82814"
MONO_VERSION="11.3.0"
MONO_URL="https://dl.winehq.org/wine/wine-mono/11.3.0/wine-mono-11.3.0-x86.tar.xz"
MONO_SHA256="54a1b0111c3fe4b785eae688af94d27e64995707ad648b6fee8000381b80d298"

# Applied in order, with patch -p1.
PATCHES=(
    patches/wine/0001-win32u-enable-host-vulkan-portability-enumeration.patch
    patches/wine/0002-ntdll-point-vulkan-loader-at-bundled-drivers.patch
)
