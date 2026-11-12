#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""manifest.py: write BUILD-INFO.json, LICENSES/, README.md and the SPDX SBOM.

Called by build/manifest.sh with everything it needs in the environment.
Standard library only (Xcode's python3 is 3.9). Nothing here reads the
clock: every value comes from the inputs, so rebuilding gives the same bytes.
"""

import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys

SCHEMA_VERSION = 1

env = os.environ
W = pathlib.Path(env["W"])
T = pathlib.Path(env["T"])              # the release tree
OUT = pathlib.Path(env["WMB_OUT_DIR"])
TC = pathlib.Path(env["TC"])
ROOT = pathlib.Path(env["WMB_ROOT"])
BUILD_ID = env["BUILD_ID"]


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def kv_file(path):
    out = {}
    for line in pathlib.Path(path).read_text().splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k] = v
    return out


def port(*args):
    return subprocess.run([str(TC / "bin/port"), "-q", *args], check=True,
                          capture_output=True, text=True).stdout.strip()


def port_for(path):
    # "port provides" answers "<path> is provided by: <port>"
    out = port("provides", str(path))
    return out.rsplit(":", 1)[-1].strip() if "provided by" in out else None


def port_version(name):
    # "  gnutls @3.8.13_0+... (active)" -> "3.8.13_0"
    for line in port("installed", name).splitlines():
        if "(active)" in line:
            return line.split("@", 1)[1].split()[0].split("+")[0]
    return None


def git(*args):
    try:
        return subprocess.run(["git", "-C", str(ROOT), *args], check=True,
                              capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None


# --- Components ---------------------------------------------------------------
components = []

components.append({
    "name": "wine",
    "version": env["WINE_VERSION"],
    "license": "LGPL-2.1-or-later",
    "source": {"url": env["WINE_URL"], "sha256": env["WINE_SHA256"],
               "signed_by": env.get("WINE_SIGNING_KEY")},
    "patches": [{"file": p, "sha256": sha256(ROOT / p)}
                for p in env.get("PATCHES", "").split() if p],
})

licenses_dir = T / "LICENSES"
if licenses_dir.exists():
    shutil.rmtree(licenses_dir)
licenses_dir.mkdir()
(licenses_dir / "wine").mkdir()
for name in ("COPYING.LIB", "LICENSE", "AUTHORS"):
    shutil.copy(W / "src" / name, licenses_dir / "wine" / name)

bundled = []
seen_ports = {}
for line in (W / "bundled-libs.txt").read_text().splitlines():
    name, origin = line.split(" ", 1)
    p = port_for(origin)
    bundled.append({"file": f"lib/{name}", "port": p,
                    "sha256": sha256(T / "lib" / name)})
    if p and p not in seen_ports:
        seen_ports[p] = True

missing_licenses = []
for p in sorted(seen_ports):
    lic_src = TC / "share/wmb/licenses" / p
    lic_field = (lic_src / "MACPORTS-LICENSE-FIELD").read_text().strip() if lic_src.exists() else None
    components.append({"name": p, "version": port_version(p), "license_macports": lic_field,
                       "from": "MacPorts, built from source in the toolchain"})
    if lic_src.exists() and any(f.name != "MACPORTS-LICENSE-FIELD" for f in lic_src.iterdir()):
        shutil.copytree(lic_src, licenses_dir / p, ignore=shutil.ignore_patterns("MACPORTS-LICENSE-FIELD"))
    else:
        missing_licenses.append(p)

tc_info = {}
for line in (TC / "share/wmb/toolchain.txt").read_text().splitlines():
    if ": " in line and not line.startswith(" "):
        k, v = line.split(": ", 1)
        tc_info[k] = v

for key, name, lic in (("moltenvk", "MoltenVK", "Apache-2.0"),
                       ("gstreamer", "GStreamer.framework", "LGPL-2.0-or-later")):
    version, digest = tc_info[key].split()
    components.append({"name": name, "version": version, "license": lic, "sha256": digest})

# MoltenVK's LICENSE, kept from its release archive by the toolchain.
mvk_lic = TC / "share/wmb/licenses/MoltenVK"
if mvk_lic.is_dir() and any(mvk_lic.iterdir()):
    shutil.copytree(mvk_lic, licenses_dir / "MoltenVK")
else:
    missing_licenses.append("MoltenVK")
# GStreamer.framework ships the licences of everything in it; point at them
# rather than keep a second copy.
gst_lic = "lib/GStreamer.framework/Versions/1.0/share/licenses"
if (T / gst_lic).is_dir() and any((T / gst_lic).iterdir()):
    (licenses_dir / "GStreamer.framework").symlink_to("../" + gst_lic)
else:
    missing_licenses.append("GStreamer.framework")

components.append({"name": "wine-gecko", "version": env["GECKO_VERSION"], "license": "MPL-2.0",
                   "files": [{"url": env["GECKO_X86_URL"], "sha256": env["GECKO_X86_SHA256"]},
                             {"url": env["GECKO_X86_64_URL"], "sha256": env["GECKO_X86_64_SHA256"]}]})
components.append({"name": "wine-mono", "version": env["MONO_VERSION"],
                   "license": "MIT AND others (see its own licence files)",
                   "files": [{"url": env["MONO_URL"], "sha256": env["MONO_SHA256"]}]})

# --- BUILD-INFO.json ------------------------------------------------------------
compile_env = kv_file(W / "compile-env.txt")
commit = git("rev-parse", "HEAD")
dirty = bool(git("status", "--porcelain")) if commit else None

info = {
    "schema_version": SCHEMA_VERSION,
    "build_id": BUILD_ID,
    "build_name": env["BUILD_NAME"],
    "flavour": env["FLAVOUR"],
    "wine_version": env["WINE_VERSION"],
    "revision": int(env["BUILD_REVISION"]),
    "platform": "macos-x86_64",
    "minimum_macos": env["DEPLOYMENT_TARGET"],
    "source_date_epoch": int(env["WINE_RELEASE_EPOCH"]),
    "recipe": {"repository": env.get("WMB_REPO_URL"), "commit": commit, "uncommitted_changes": dirty},
    "environment": {
        "lane": env.get("WMB_LANE", "local"),
        "tart_image": tc_info.get("tart_image"),
        "macos": compile_env.get("MACOS"),
        "xcode": compile_env.get("XCODE"),
        "sdk": compile_env.get("SDK"),
        "cc": compile_env.get("CC_VERSION"),
        "mingw_cc": compile_env.get("MINGW_CC_VERSION"),
        "ci_run": env.get("GITHUB_SERVER_URL", "") + "/" + env.get("GITHUB_REPOSITORY", "") +
                  "/actions/runs/" + env["GITHUB_RUN_ID"] if env.get("GITHUB_RUN_ID") else None,
    },
    "toolchain": {"id": env["TOOLCHAIN"], **{k: v for k, v in tc_info.items() if k != "toolchain"}},
    "configure": {k: compile_env.get(k) for k in (
        "CONFIGURE_ARGS", "CC", "CFLAGS", "CPPFLAGS", "LDFLAGS",
        "CROSSCFLAGS", "CROSSLDFLAGS", "CROSSDEBUG", "MACOSX_DEPLOYMENT_TARGET")},
    "components": components,
    "bundled_libraries": bundled,
    "licenses_missing": missing_licenses,
}
text = json.dumps(info, indent=2, sort_keys=False) + "\n"
(T / "BUILD-INFO.json").write_text(text)
OUT.mkdir(parents=True, exist_ok=True)
(OUT / f"{BUILD_ID}.build-info.json").write_text(text)

# --- README.md -------------------------------------------------------------------
repo = env.get("WMB_REPO_URL") or "(repository not set)"
(T / "README.md").write_text(f"""# {BUILD_ID}

Wine {env['WINE_VERSION']} for macOS (x86_64, runs under Rosetta 2 on Apple
silicon), built by wine-mac-binaries: {repo}

- Flavour: `{env['FLAVOUR']}`. {env.get('FLAVOUR_DESCRIPTION', '')}
- Build revision: r{env['BUILD_REVISION']}
- Minimum macOS: {env['DEPLOYMENT_TARGET']}

`BUILD-INFO.json` says exactly what went into this build: sources, patches,
toolchain, compiler flags and every bundled library. `LICENSES/` has the
licence of each component.

## Running it

    xattr -dr com.apple.quarantine {BUILD_ID}   # if it was downloaded by a browser
    ./{BUILD_ID}/bin/wine winecfg

This is not an official WineHQ build. Report problems with this build to
{repo}/issues, not to WineHQ, unless they also happen with WineHQ's own
packages.
""")

# --- SPDX SBOM -------------------------------------------------------------------
def spdx_id(name):
    return "SPDXRef-" + "".join(c if c.isalnum() or c in ".-" else "-" for c in name)


packages = []
for c in components:
    pkg = {
        "SPDXID": spdx_id(c["name"]),
        "name": c["name"],
        "versionInfo": c.get("version") or "NOASSERTION",
        "downloadLocation": (c.get("source") or {}).get("url") or
                            ((c.get("files") or [{}])[0].get("url")) or "NOASSERTION",
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": c["license"] if c.get("license", "").replace("-", "").replace(".", "").replace(" ", "").isalnum() else "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "filesAnalyzed": False,
    }
    if c.get("license_macports"):
        pkg["comment"] = f"MacPorts licence field: {c['license_macports']}"
    packages.append(pkg)

sbom = {
    "spdxVersion": "SPDX-2.3",
    "dataLicense": "CC0-1.0",
    "SPDXID": "SPDXRef-DOCUMENT",
    "name": BUILD_ID,
    "documentNamespace": f"{repo}/spdx/{BUILD_ID}",
    "creationInfo": {
        "created": subprocess.run(["date", "-u", "-r", env["WINE_RELEASE_EPOCH"], "+%Y-%m-%dT%H:%M:%SZ"],
                                  check=True, capture_output=True, text=True).stdout.strip(),
        "creators": ["Tool: wine-mac-binaries build/manifest.py"],
    },
    "packages": packages,
    "relationships": [{"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES",
                       "relatedSpdxElement": spdx_id("wine")}] +
                     [{"spdxElementId": spdx_id("wine"), "relationshipType": "CONTAINS",
                       "relatedSpdxElement": p["SPDXID"]} for p in packages if p["name"] != "wine"],
}
(OUT / f"{BUILD_ID}.spdx.json").write_text(json.dumps(sbom, indent=2) + "\n")

if missing_licenses:
    print("warning: no licence text for: " + ", ".join(missing_licenses), file=sys.stderr)
