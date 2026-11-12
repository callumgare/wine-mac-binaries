# wine-mac-binaries

Builds of [Wine](https://www.winehq.org) for macOS, made automatically for
every Wine release. They're for apps that bundle Wine and for people who
want a specific Wine version that will still be downloadable years from now.

> **Status: not released yet.** The build scripts are being written and tested.
> Nothing published so far is permanent.

## Goals

1. **Stable.** A published build is never removed or changed. Old versions
   stay downloadable at the same URL. The only exception is a build that is
   marked *experimental* when it's published.
2. **Transparent.** Every step from WineHQ's source to the file you download
   is in this repository. Each build records exactly what went into it: the
   source and patches, toolchain, compiler flags and every bundled library.
   You can check it with `gh attestation verify`, and you can rebuild it
   yourself.
3. **Automated.** New Wine releases are built, tested and published by CI.
   A person steps in only when something fails.

The contents of each build closely follow [Gcenx's](https://github.com/Gcenx/macports-wine)
widely used macOS builds: the same configure options, bundled libraries,
Gecko and Mono, and macOS patches. Every difference is listed, with its
reason, in [plan.md](plan.md#deviations-from-gcenxs-builds).

## Building

The same commands run on a developer's Mac and in CI:

```sh
./wmb vm toolchain 20261111 --archive   # once: the libraries and compilers, in a fresh VM
./wmb vm build wine 11.21               # -> vm-share/out/wine-11.21-r1-macos-x86_64.tar.xz
```

`./wmb vm …` runs the command inside a clean macOS VM ([Tart](https://tart.run))
from the image pinned in `toolchains/<id>.sh`. That's how releases are made.
`./wmb build …` runs on the current Mac instead, which is quicker for
development.

| Path | What it is |
|---|---|
| `wmb` | the entry point |
| `build/` | the build steps: `toolchain`, `compile`, `package`, `manifest`, `archive`, `vm` |
| `toolchains/<id>.sh` | a pinned toolchain: Tart image, MacPorts and ports-tree commits, prebuilt tools |
| `flavours/<name>.sh` | configure options for each flavour |
| `inputs/<flavour>/<version>.sh` | pinned sources for one version (written by `tools/pin`) |
| `patches/` | patches, each with a header saying where it came from and why |
| `tools/compare` | fingerprints two builds and reports the differences |
| `keys/` | WineHQ's release signing key |

## Licence

LGPL-2.1-or-later, the same as Wine. Each build carries the licences of
everything it bundles in its `LICENSES/` folder.

This project isn't affiliated with WineHQ or CodeWeavers.
