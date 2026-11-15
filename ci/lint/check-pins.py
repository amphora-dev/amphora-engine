#!/usr/bin/env python3
"""Check the values that are written down in more than one place.

BuildStream stages sources without .git, and Wine's configure is driven from
scripts/wine.sh rather than project.conf, so a few facts are necessarily repeated:

- the Wine commit: wine/wine.bst source `ref` == runtime.bst `WINE_COMMIT`
  (the runtime archive name and manifest are built from the latter);
- the FEX commit: fex/fex.bst source `ref` == its `FEX_COMMIT`, and
  `FEX_DESCRIBE` names the same commit (…-g<commit7>);
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
    elif not fex_env["FEX_DESCRIBE"].endswith("-g" + fex_env["FEX_COMMIT"][:7]):
        errors.append(f"FEX_DESCRIBE {fex_env['FEX_DESCRIBE']} is not commit {fex_env['FEX_COMMIT'][:7]}")

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
    print(f"pins consistent (Wine {git[0]['ref'][:12]}, FEX {fex_env['FEX_COMMIT'][:7]}, API {next(iter(api.values()))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
