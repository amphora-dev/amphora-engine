#!/usr/bin/env python3
"""Carry BuildStream's local cache between CI runs as a GitHub Actions cache snapshot.

A runner starts with an empty ~/.cache/buildstream. The snapshot puts back only
what is expensive to recreate:

  - the artifacts of this project's own elements in the target's dependency
    graph (Wine, its libraries, the runtime archive), at their current keys;
  - the stored ccache directories (scripts/ccache-cas.py): one tar each, named
    by an action cache entry.

SDK artifacts from the buildstream-sdk junction (host SDK, NDK, llvm-mingw)
are left out: BuildStream refetches their pinned sources and rebuilds them
when an element that needs them has to build. See docs/CACHE.md.

  snapshot.py export DIR [--target ELEMENT]
  snapshot.py import DIR

Run with the BuildStream venv's python (ci/cache/snapshot.sh); it provides the
REAPI and BuildStream protos. Layout written by buildbox-casd and BuildStream:

  cas/objects/<h[:2]>/<h[2:]>          blobs: files, Directory protos, Actions
  actioncache/objects/<h[:2]>/<h[2:]>  ActionResult keyed by the Action digest
  artifacts/refs/<project>/<element>/<key>  Artifact proto (strong and weak key)
"""
from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
from pathlib import Path

from google.protobuf.message import DecodeError, Message

from buildstream._protos.build.bazel.remote.execution.v2 import remote_execution_pb2 as re_pb2
from buildstream._protos.buildstream.v2 import artifact_pb2

ROOT = Path(__file__).resolve().parents[2]
CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "buildstream"
CAS = CACHE / "cas" / "objects"
AC = CACHE / "actioncache" / "objects"
REFS = CACHE / "artifacts" / "refs"
EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
# Artifact fields that point at a Directory tree rather than a single blob.
TREES = {"files", "buildtree", "sources", "buildroot", "subsandbox_digests"}


def obj(root: Path, h: str) -> Path:
    return root / h[:2] / h[2:]


def link(src: Path, dst: Path, replace: bool = False) -> bool:
    """Hard link (or copy) src to dst. An existing dst is kept, or with
    `replace` atomically replaced when its content differs."""
    if dst.exists() and (not replace or dst.read_bytes() == src.read_bytes()):
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.name}.{os.getpid()}")
    try:
        os.link(src, tmp)
    except OSError:
        shutil.copy2(src, tmp)
    os.replace(tmp, dst)
    return True


# --- element artifacts ---------------------------------------------------------


def tree(d: re_pb2.Digest, out: dict[str, int]) -> bool:
    """Add a Directory and everything under it; False if any part is missing."""
    p = obj(CAS, d.hash)
    if not p.exists():
        return False
    out[d.hash] = d.size_bytes
    node = re_pb2.Directory()
    node.ParseFromString(p.read_bytes())
    ok = True
    for f in node.files:
        out[f.digest.hash] = f.digest.size_bytes
        ok &= obj(CAS, f.digest.hash).exists()
    for sub in node.directories:
        ok &= tree(sub.digest, out)
    return ok


def artifact_blobs(msg, out: dict[str, int], name: str = "") -> bool:
    """Every blob an Artifact proto names. Optional parts (build tree, sources)
    that this machine does not have are skipped; the files tree is required."""
    if isinstance(msg, re_pb2.Digest):
        if not msg.hash or msg.hash == EMPTY:
            return True
        if name in TREES:
            part: dict[str, int] = {}
            if tree(msg, part):
                out.update(part)
                return True
            return name != "files"
        if obj(CAS, msg.hash).exists():
            out[msg.hash] = msg.size_bytes
        return True
    ok = True
    for field, value in msg.ListFields():
        if field.message_type is None:
            continue
        for v in [value] if isinstance(value, Message) else value:
            ok &= artifact_blobs(v, out, field.name)
    return ok


def project_elements(target: str) -> list[tuple[str, str]]:
    """(element name, full key) for this project's elements in the target's graph."""
    out = subprocess.run(
        [str(ROOT / "bst"), "--no-colors", "show", "--deps", "all", "--format", "%{name}\t%{full-key}", target],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    rows = [line.split("\t") for line in out.splitlines() if "\t" in line]
    # Junction elements show as "junction.bst:element.bst"; they stay out.
    return [(n, k) for n, k in rows if ":" not in n]


def project_name() -> str:
    for line in (ROOT / "project.conf").read_text().splitlines():
        if line.startswith("name:"):
            return line.split(":", 1)[1].strip()
    raise SystemExit("project.conf has no name")


def export_artifacts(dest: Path, target: str, seen: dict[str, int]) -> tuple[int, int]:
    project = project_name()
    kept = missing = 0
    for name, key in project_elements(target):
        el_dir = REFS / project / os.path.splitext(name.replace("/", "-"))[0]
        ref = el_dir / key
        if not ref.exists():
            missing += 1
            continue
        art = artifact_pb2.Artifact()
        art.ParseFromString(ref.read_bytes())
        # A failed build is cached too; carried over, it would stop the next
        # run at the same key from retrying (build.retry-failed is off).
        if not art.build_success:
            missing += 1
            continue
        need: dict[str, int] = {}
        if not artifact_blobs(art, need):
            missing += 1
            continue
        for h in need:
            link(obj(CAS, h), obj(dest / "cas", h))
        seen.update(need)
        # The same artifact is stored under its strong and weak (and strict) key.
        for k in {key, art.strong_key, art.weak_key, art.strict_key} - {""}:
            src = el_dir / k
            if src.exists() and src.read_bytes() == ref.read_bytes():
                dst = dest / "refs" / project / el_dir.name / k
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
        kept += 1
    return kept, missing


# --- ccache (scripts/ccache-cas.py) ----------------------------------------------

CCACHE_TAR = "ccache.tar"


def ccache_entries():
    """(action hash, ActionResult) for the entries ccache-cas wrote: a single
    output file named ccache.tar. Anything else in the action cache (such as
    leftovers of older tools) stays out of the snapshot."""
    if not AC.is_dir():
        return
    for sub in sorted(AC.iterdir()):
        for f in sorted(sub.iterdir()):
            r = re_pb2.ActionResult()
            try:
                r.ParseFromString(f.read_bytes())
            except DecodeError:
                continue
            if [o.path for o in r.output_files] == [CCACHE_TAR] and not r.output_directories:
                yield sub.name + f.name, r


def export_ccache(dest: Path, seen: dict[str, int]) -> list[str]:
    """Each entry with its tar, Action and Command; entries whose tar casd has
    expired are skipped. Returns "name size" descriptions."""
    out = []
    for action, r in ccache_entries():
        tar = r.output_files[0].digest
        if not obj(CAS, tar.hash).exists():
            continue
        blobs = {tar.hash: tar.size_bytes}
        name = action[:12]
        p = obj(CAS, action)
        if p.exists():
            blobs[action] = p.stat().st_size
            a = re_pb2.Action()
            a.ParseFromString(p.read_bytes())
            c = obj(CAS, a.command_digest.hash)
            if c.exists():
                blobs[a.command_digest.hash] = a.command_digest.size_bytes
                cmd = re_pb2.Command()
                cmd.ParseFromString(c.read_bytes())
                name = " ".join(cmd.arguments[1:]) or name
        for h, size in blobs.items():
            link(obj(CAS, h), obj(dest / "cas", h))
            seen[h] = size
        link(obj(AC, action), obj(dest / "ac", action))
        out.append(f"{name} {tar.size_bytes / 2**30:.2f} GiB")
    return out


# --- commands ------------------------------------------------------------------


def export(dest: Path, target: str) -> None:
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    seen: dict[str, int] = {}
    arts, art_missing = export_artifacts(dest, target, seen)
    if arts == 0:
        # Shown as an annotation on GitHub. Most likely a BuildStream upgrade
        # changed the ref layout or the Artifact proto this script reads.
        print("::warning::snapshot: no element artifacts exported; check ci/cache/snapshot.py against this BuildStream")
    art_size = sum(seen.values())
    caches = export_ccache(dest, seen)
    print(
        f"snapshot: {arts} artifacts ({art_size / 2**30:.2f} GiB"
        + (f", {art_missing} not cached" if art_missing else "")
        + f"), ccache: {', '.join(caches) or 'none'}; {len(seen)} blobs -> {dest}"
    )


def import_(src: Path) -> None:
    if not (src / "cas").is_dir():
        print(f"snapshot: nothing at {src}")
        return
    n = 0
    # Action cache entries name the stored ccache directories; the snapshot's
    # replace this machine's, so a dev machine that pulls a CI run
    # (ci/cache/pull-ci.sh) builds with CI's compile results.
    for root, dst, replace in ((src / "cas", CAS, False), (src / "ac", AC, True)):
        if not root.is_dir():
            continue
        for sub in root.iterdir():
            for f in sub.iterdir():
                n += link(f, dst / sub.name / f.name, replace)
    refs = 0
    if (src / "refs").is_dir():
        for f in (src / "refs").rglob("*"):
            if f.is_file():
                dst = REFS / f.relative_to(src / "refs")
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(f, dst)
                refs += 1
    print(f"snapshot: imported {refs} artifact refs, {n} new cache files from {src}")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("dir", type=lambda v: Path(v).expanduser())
    e.add_argument("--target", default="runtime.bst")
    i = sub.add_parser("import")
    i.add_argument("dir", type=lambda v: Path(v).expanduser())
    a = p.parse_args()
    if a.cmd == "export":
        export(a.dir, a.target)
    else:
        import_(a.dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
