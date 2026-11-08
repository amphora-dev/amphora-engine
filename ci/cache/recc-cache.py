#!/usr/bin/env python3
"""Move recc's action cache between BuildStream's local cache and its two upper levels.

    L1  GitHub Actions cache: a snapshot directory with only the recc action
        results and the blobs they name (export / import).
    L2  the shared remote cache (Phoenix): the same entries over REAPI (push).

BuildStream's own CAS also holds the SDK, sources, element artifacts and build
trees (18 GB on a dev machine); those go to the remote cache's artifact and
source services instead and never into a snapshot. See docs/CACHE.md.

  recc-cache.py export DIR [--budget GiB]   newest entries + blobs into DIR (hard links)
  recc-cache.py import DIR                  link DIR into the local cache
  recc-cache.py push [--all] [--limit N]    upload entries L2 does not have yet
  recc-cache.py check [--limit N]           how many local entries L2 returns

Run with the BuildStream venv's python (it provides grpc and the REAPI protos).
Layout used by buildbox-casd: <cache>/actioncache/objects/<h[:2]>/<h[2:]> holds a
serialized ActionResult keyed by the Action digest; the Action itself and every
output blob are <cache>/cas/objects/<h[:2]>/<h[2:]>.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import os
import shutil
import sys
import time
import uuid
from pathlib import Path

from buildstream._protos.build.bazel.remote.execution.v2 import remote_execution_pb2 as re_pb2

CACHE = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache")) / "buildstream"
AC = CACHE / "actioncache" / "objects"
CAS = CACHE / "cas" / "objects"
# Entries already in L2: imported from a snapshot (each snapshot entry was
# written back when it was created) or pushed from here. `push` skips them.
KNOWN = CACHE.parent / "amphora-recc-known.txt"
EMPTY = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"


def obj(root: Path, h: str) -> Path:
    return root / h[:2] / h[2:]


def entries(ac: Path = AC):
    """(action hash, ActionResult) for every local action result."""
    if not ac.is_dir():
        return
    for sub in sorted(ac.iterdir()):
        for f in sub.iterdir():
            r = re_pb2.ActionResult()
            r.ParseFromString(f.read_bytes())
            yield sub.name + f.name, r


def blobs(action: str, r: re_pb2.ActionResult) -> list[tuple[str, int]]:
    """Every CAS blob an entry needs: the Action, outputs, stdout/stderr."""
    out = [(action, obj(CAS, action).stat().st_size)]
    out += [(o.digest.hash, o.digest.size_bytes) for o in r.output_files]
    for d in (r.stdout_digest, r.stderr_digest):
        if d.hash and d.hash != EMPTY:
            out.append((d.hash, d.size_bytes))
    if r.output_directories:
        raise SystemExit(f"{action}: output directories are not handled (recc only writes files)")
    return out


def link(src: Path, dst: Path) -> bool:
    if dst.exists():
        return False
    dst.parent.mkdir(parents=True, exist_ok=True)
    try:
        os.link(src, dst)
    except OSError:
        shutil.copy2(src, dst)
    return True


def export(dest: Path, budget: float) -> None:
    """Newest entries first (by the AC file's mtime) until `budget` GiB of blobs."""
    if dest.exists():
        shutil.rmtree(dest)
    found = []
    for action, r in entries():
        try:
            bl = blobs(action, r)
            mtime = obj(AC, action).stat().st_mtime
        except FileNotFoundError:
            continue  # casd expired a blob; the entry is a miss anyway
        if all(obj(CAS, h).exists() for h, _ in bl):
            found.append((mtime, action, bl))
    found.sort(reverse=True)
    limit = budget * 2**30
    total = kept = 0
    seen: set[str] = set()
    for _, action, bl in found:
        size = sum(s for h, s in bl if h not in seen)
        if total + size > limit:
            break
        for h, _ in bl:
            if h not in seen:
                seen.add(h)
                link(obj(CAS, h), obj(dest / "cas", h))
        link(obj(AC, action), obj(dest / "ac", action))
        total += size
        kept += 1
    print(f"recc snapshot: {kept}/{len(found)} entries, {len(seen)} blobs, {total / 2**30:.2f} GiB -> {dest}")


def import_(src: Path) -> None:
    if not (src / "ac").is_dir():
        print(f"recc snapshot: nothing at {src}")
        return
    n = 0
    for root, dst in ((src / "cas", CAS), (src / "ac", AC)):
        for sub in root.iterdir():
            for f in sub.iterdir():
                n += link(f, dst / sub.name / f.name)
    names = [a for a, _ in entries(src / "ac")]
    remember(names)
    print(f"recc snapshot: {len(names)} entries imported ({n} new files) from {src}")


def remember(actions) -> None:
    with KNOWN.open("a") as f:
        f.writelines(a + "\n" for a in actions)


def channel():
    import grpc

    url = os.environ.get("BST_REMOTE_CACHE_URL", "https://cas.arm.512.pub")
    conf = Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
    token = (conf / "bst-remote-cache.token").read_text().strip()
    host = url.split("://", 1)[1].rstrip("/")
    if ":" not in host:
        host += ":443" if url.startswith("https") else ":80"
    creds = grpc.composite_channel_credentials(
        grpc.ssl_channel_credentials(), grpc.access_token_call_credentials(token)
    )
    return grpc.secure_channel(
        host, creds, options=[("grpc.max_send_message_length", 64 << 20), ("grpc.max_receive_message_length", 64 << 20)]
    )


def push(push_all: bool, limit: int | None, jobs: int) -> None:
    from buildstream._protos.build.bazel.remote.execution.v2 import remote_execution_pb2_grpc as re_grpc
    from buildstream._protos.google.bytestream import bytestream_pb2, bytestream_pb2_grpc

    skip = set() if push_all or not KNOWN.exists() else set(KNOWN.read_text().split())
    todo = []
    for action, r in entries():
        if action in skip:
            continue
        try:
            todo.append((action, r, blobs(action, r)))
        except FileNotFoundError:
            continue
        if limit and len(todo) >= limit:
            break
    if not todo:
        print("recc push: nothing new")
        return

    start = time.monotonic()
    ch = channel()
    cas = re_grpc.ContentAddressableStorageStub(ch)
    ac = re_grpc.ActionCacheStub(ch)
    bs = bytestream_pb2_grpc.ByteStreamStub(ch)

    want = {h: s for _, _, bl in todo for h, s in bl}
    missing: list[tuple[str, int]] = []
    keys = list(want)
    for i in range(0, len(keys), 2000):
        req = re_pb2.FindMissingBlobsRequest(
            blob_digests=[re_pb2.Digest(hash=h, size_bytes=want[h]) for h in keys[i : i + 2000]]
        )
        missing += [(d.hash, d.size_bytes) for d in cas.FindMissingBlobs(req, timeout=300).missing_blob_digests]

    def put_batch(group):
        req = re_pb2.BatchUpdateBlobsRequest(
            requests=[
                re_pb2.BatchUpdateBlobsRequest.Request(
                    digest=re_pb2.Digest(hash=h, size_bytes=s), data=obj(CAS, h).read_bytes()
                )
                for h, s in group
            ]
        )
        for resp in cas.BatchUpdateBlobs(req, timeout=600).responses:
            if resp.status.code:
                raise RuntimeError(f"upload {resp.digest.hash}: {resp.status.message}")

    def put_stream(h, s):
        name = f"uploads/{uuid.uuid4()}/blobs/{h}/{s}"

        def chunks():
            with obj(CAS, h).open("rb") as f:
                off = 0
                while True:
                    data = f.read(1 << 20)
                    last = off + len(data) >= s
                    yield bytestream_pb2.WriteRequest(resource_name=name, write_offset=off, data=data, finish_write=last)
                    off += len(data)
                    if last:
                        return

        bs.Write(chunks(), timeout=1800)

    small = sorted((b for b in missing if b[1] < 1 << 20), key=lambda b: b[1])
    groups, cur, size = [], [], 0
    for b in small:
        if cur and size + b[1] > 3 << 20:
            groups.append(cur)
            cur, size = [], 0
        cur.append(b)
        size += b[1]
    if cur:
        groups.append(cur)
    with cf.ThreadPoolExecutor(jobs) as pool:
        futs = [pool.submit(put_batch, g) for g in groups]
        futs += [pool.submit(put_stream, h, s) for h, s in missing if s >= 1 << 20]
        for f in cf.as_completed(futs):
            f.result()

    def put_result(action, r):
        size = obj(CAS, action).stat().st_size
        ac.UpdateActionResult(
            re_pb2.UpdateActionResultRequest(action_digest=re_pb2.Digest(hash=action, size_bytes=size), action_result=r),
            timeout=120,
        )

    with cf.ThreadPoolExecutor(jobs) as pool:
        for f in cf.as_completed([pool.submit(put_result, a, r) for a, r, _ in todo]):
            f.result()
    remember(a for a, _, _ in todo)

    up = sum(s for _, s in missing)
    print(
        f"recc push: {len(todo)} entries, {len(missing)}/{len(want)} blobs uploaded "
        f"({up / 2**20:.0f} MiB) in {time.monotonic() - start:.0f} s"
    )


def check(limit: int, jobs: int) -> None:
    """How many of the first `limit` local entries the remote action cache returns."""
    import grpc
    from buildstream._protos.build.bazel.remote.execution.v2 import remote_execution_pb2_grpc as re_grpc

    ac = re_grpc.ActionCacheStub(channel())

    def get(action):
        size = obj(CAS, action).stat().st_size
        try:
            ac.GetActionResult(
                re_pb2.GetActionResultRequest(action_digest=re_pb2.Digest(hash=action, size_bytes=size)), timeout=60
            )
            return True
        except grpc.RpcError as e:
            if e.code() == grpc.StatusCode.NOT_FOUND:
                return False
            raise

    actions = []
    for action, _ in entries():
        actions.append(action)
        if len(actions) >= limit:
            break
    with cf.ThreadPoolExecutor(jobs) as pool:
        hits = sum(pool.map(get, actions))
    print(f"recc check: remote has {hits}/{len(actions)} of the local entries")


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export")
    e.add_argument("dir", type=Path)
    e.add_argument("--budget", type=float, default=4.0, help="GiB of blobs to keep (default 4)")
    i = sub.add_parser("import")
    i.add_argument("dir", type=Path)
    u = sub.add_parser("push")
    u.add_argument("--all", action="store_true", help="also entries recorded as already in L2")
    u.add_argument("--limit", type=int, help="at most N entries (testing)")
    u.add_argument("--jobs", type=int, default=16)
    c = sub.add_parser("check")
    c.add_argument("--limit", type=int, default=200)
    c.add_argument("--jobs", type=int, default=16)
    a = p.parse_args()
    if a.cmd == "export":
        export(a.dir, a.budget)
    elif a.cmd == "import":
        import_(a.dir)
    elif a.cmd == "check":
        check(a.limit, a.jobs)
    else:
        push(a.all, a.limit, a.jobs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
