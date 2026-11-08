#!/usr/bin/env python3
"""Check the values that are written down in more than one place.

BuildStream stages sources without .git, and Wine's configure is driven from
ci/wine.sh rather than project.conf, so a few facts are necessarily repeated:

- the Wine commit: wine/wine.bst source `ref` == runtime.bst `WINE_COMMIT`
  (the runtime archive name and manifest are built from the latter);
- the Android API level: project.conf `target-triple`, ci/wine.sh `TARGET`,
  the meson cross file in project.conf, and `minSdk` in ci/runtime.sh.
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

    conf = load("project.conf")
    api = {
        "project.conf target-triple": grab("project.conf", r"^\s*target-triple:\s*aarch64-linux-android(\d+)\s*$"),
        "project.conf meson cross file": re.search(
            r"meson-aarch64-android(\d+)\.ini", conf["elements"]["meson"]["variables"]["meson-global"]
        ).group(1),
        "ci/wine.sh TARGET": grab("ci/wine.sh", r"^TARGET=aarch64-linux-android(\d+)\s*$"),
        "ci/runtime.sh minSdk": grab("ci/runtime.sh", r'"minSdk":\s*(\d+)'),
    }
    if len(set(api.values())) != 1:
        errors.append("Android API levels differ: " + ", ".join(f"{k}={v}" for k, v in api.items()))

    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"pins consistent (Wine {git[0]['ref'][:12]}, API {next(iter(api.values()))})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
