#!/usr/bin/env python3
"""Check the values that are written down in more than one place.

BuildStream stages sources without .git, and Wine's configure is driven from
scripts/wine.sh rather than project.conf, so a few facts are necessarily repeated:

- the Wine commit: wine/wine.bst source `ref` == runtime.bst `WINE_COMMIT`
  (the runtime archive name and manifest are built from the latter);
- the FEX commit: fex/fex.bst source `ref` == its `FEX_COMMIT`, and
  `FEX_DESCRIBE` names the same commit (…-g<commit7>, or exactly the tag
  the source tracks);
- the DXVK and vkd3d-proton commits: each element's source `ref` == its
  `DXVK_COMMIT` / `VKD3D_COMMIT` (the runtime's manifest and name are built
  from them), and the version strings written next to them name that commit;
- the Mesa version: mesa/turnip.bst's tarball == its `MESA_VERSION`;
- the Android API level: project.conf `target-triple` and the meson cross
  file next to it. Wine (scripts/wine.sh) and the manifest's minSdk
  (scripts/runtime.sh) read `target-triple` through TARGET_TRIPLE.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]


def load(rel: str) -> dict:
    return yaml.safe_load((ROOT / rel).read_text(encoding="utf-8"))


def grab(rel: str, pattern: str) -> str:
    m = re.search(pattern, (ROOT / rel).read_text(encoding="utf-8"), re.M)
    if not m:
        raise SystemExit(f"{rel}: no match for {pattern!r}")
    return m.group(1)


def main() -> int:
    errors: list[str] = []

    wine = load("elements/wine/wine.bst")
    runtime = load("elements/runtime.bst")
    git = [s for s in wine["sources"] if s.get("kind") == "git"]
    if len(git) != 1:
        errors.append("wine/wine.bst: expected exactly one git source")
    else:
        ref = git[0]["ref"]
        pinned = runtime["environment"]["WINE_COMMIT"]
        if ref != pinned:
            errors.append(f"Wine commit: wine/wine.bst ref {ref} != runtime.bst WINE_COMMIT {pinned}")

    fex = load("elements/fex/fex.bst")
    fex_git = [s for s in fex["sources"] if s.get("kind") == "git"]
    fex_env = fex["environment"]
    if len(fex_git) != 1:
        errors.append("fex/fex.bst: expected exactly one git source")
    elif fex_git[0]["ref"] != fex_env["FEX_COMMIT"]:
        errors.append(f"FEX commit: fex/fex.bst ref {fex_git[0]['ref']} != FEX_COMMIT {fex_env['FEX_COMMIT']}")
    elif not (
        fex_env["FEX_DESCRIBE"].endswith("-g" + fex_env["FEX_COMMIT"][:7])
        or fex_env["FEX_DESCRIBE"] == fex_git[0].get("track")
    ):
        errors.append(f"FEX_DESCRIBE {fex_env['FEX_DESCRIBE']} is not commit {fex_env['FEX_COMMIT'][:7]}")

    for rel, commit_var, version_vars in (
        ("elements/dxvk/dxvk.bst", "DXVK_COMMIT", ("DXVK_DESCRIBE",)),
        ("elements/vkd3d-proton/vkd3d-proton.bst", "VKD3D_COMMIT", ("VKD3D_BUILD", "VKD3D_DESCRIBE")),
    ):
        element = load(rel)
        env = element["environment"]
        # The first git source is the project; the others are nested submodules.
        ref = next(s["ref"] for s in element["sources"] if s.get("kind") == "git")
        if ref != env[commit_var]:
            errors.append(f"{rel}: ref {ref} != {commit_var} {env[commit_var]}")
        for var in version_vars:
            # `git describe` output: ends in the abbreviated commit, after -g when there is a tag.
            abbrev = env[var].rsplit("-g", 1)[-1]
            if len(abbrev) < 7 or not ref.startswith(abbrev):
                errors.append(f"{rel}: {var} {env[var]} is not commit {ref[:12]}")

    turnip = load("elements/mesa/turnip.bst")
    mesa = turnip["environment"]["MESA_VERSION"]
    tarball = next(s["url"] for s in turnip["sources"] if s.get("kind") == "tar")
    if tarball != f"mesa:mesa-{mesa}.tar.xz":
        errors.append(f"mesa/turnip.bst: source {tarball} is not Mesa {mesa}")

    conf = load("project.conf")
    api = {
        "project.conf target-triple": grab("project.conf", r"^\s*target-triple:\s*aarch64-linux-android(\d+)\s*$"),
        "project.conf meson cross file": re.search(
            r"meson-aarch64-android(\d+)\.ini", conf["elements"]["meson"]["variables"]["meson-global"]
        ).group(1),
    }
    if len(set(api.values())) != 1:
        errors.append("Android API levels differ: " + ", ".join(f"{k}={v}" for k, v in api.items()))

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(
        f"pins consistent (Wine {git[0]['ref'][:12]}, FEX {fex_env['FEX_COMMIT'][:7]}, "
        f"Mesa {mesa}, API {next(iter(api.values()))})"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
