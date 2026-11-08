#!/usr/bin/env python3
"""Keep a ccache directory in BuildStream's local CAS between builds.

A BuildStream build sandbox starts empty every time, and the only way to keep
anything from one build to the next is the element's remote-apis-socket
(sandbox: remote-apis-socket in wine/wine.bst), which reaches buildbox-casd's
CAS and action cache. The whole ccache directory travels as one tar blob,
named by an action cache entry under a fixed key:

  Action{Command["amphora-ccache", NAME]} -> ActionResult{output_files: ccache.tar}

  ccache-cas restore DIR NAME   unpack the stored tar into DIR, keeping files
                                DIR already has; skipped when DIR already
                                holds that tar
  ccache-cas save DIR NAME      pack DIR and point the entry at it

Never fails the build: any error is reported and treated as an empty cache.
ci/cache/snapshot.py carries these entries (and their tars) in the CI snapshot.

REAPI messages are encoded by hand (a handful of fields) so the sandbox needs
only grpcio, which tools/ccache.bst installs next to this script.
"""
from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

# grpcio, installed by tools/ccache.bst; imported when first needed, so that a
# broken install is reported like any other error instead of failing the build.
LIB = Path(__file__).resolve().parent.parent / "lib" / "ccache-cas"
SOCKET = os.environ.get("AMPHORA_CAS_SOCKET", "/tmp/reapi.sock")
STAMP = ".cas-tar"  # in DIR: digest of the tar it was restored from or saved as
TAR = "ccache.tar"
CHUNK = 1 << 20
EMPTY = hashlib.sha256(b"").hexdigest()


# --- protobuf, just enough ----------------------------------------------------


def _varint(n: int) -> bytes:
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        out.append(b | (0x80 if n else 0))
        if not n:
            return bytes(out)


def _bytes(num: int, b: bytes) -> bytes:
    return _varint(num << 3 | 2) + _varint(len(b)) + b


def _int(num: int, n: int) -> bytes:
    return _varint(num << 3) + _varint(n) if n else b""


def _parse(b: bytes) -> dict[int, list]:
    """Field number -> values (ints for varints, bytes otherwise)."""
    out: dict[int, list] = {}
    i = 0

    def varint() -> int:
        nonlocal i
        v = shift = 0
        while True:
            c = b[i]
            i += 1
            v |= (c & 0x7F) << shift
            shift += 7
            if not c & 0x80:
                return v

    while i < len(b):
        key = varint()
        num, wt = key >> 3, key & 7
        if wt == 0:
            v = varint()
        elif wt == 2:
            n = varint()
            v, i = b[i : i + n], i + n
        elif wt in (1, 5):
            n = 8 if wt == 1 else 4
            v, i = b[i : i + n], i + n
        else:
            raise ValueError(f"wire type {wt}")
        out.setdefault(num, []).append(v)
    return out


def digest(h: str, size: int) -> bytes:  # build.bazel.remote.execution.v2.Digest
    return _bytes(1, h.encode()) + _int(2, size)


def parse_digest(b: bytes) -> tuple[str, int]:
    f = _parse(b)
    return f[1][0].decode(), f.get(2, [0])[0]


# --- REAPI over the sandbox socket -------------------------------------------

RE = "/build.bazel.remote.execution.v2."
BS = "/google.bytestream.ByteStream/"


class Cas:
    def __init__(self, socket: str):
        sys.path.insert(0, str(LIB))
        import grpc

        self.grpc = grpc
        self.ch = grpc.insecure_channel(
            "unix:" + socket,
            options=[("grpc.max_receive_message_length", -1), ("grpc.max_send_message_length", -1)],
        )

    def _unary(self, method: str, req: bytes) -> bytes:
        return self.ch.unary_unary(method)(req, timeout=600)

    def missing(self, blobs: list[tuple[str, int]]) -> set[str]:
        """FindMissingBlobs. casd also bumps the mtime of every blob it has,
        which keeps them recent for its LRU and for ci/cache/snapshot.py."""
        req = b"".join(_bytes(2, digest(h, s)) for h, s in blobs)
        resp = _parse(self._unary(RE + "ContentAddressableStorage/FindMissingBlobs", req))
        return {parse_digest(d)[0] for d in resp.get(2, [])}

    def write(self, h: str, size: int, chunks) -> None:
        name = f"uploads/{uuid.uuid4()}/blobs/{h}/{size}"

        def reqs():
            off = 0
            first = True
            for data in chunks:
                off2 = off + len(data)
                yield (_bytes(1, name.encode()) if first else b"") + _int(2, off) + _int(3, off2 == size) + _bytes(10, data)
                first = False
                off = off2
            if first:  # empty blob
                yield _bytes(1, name.encode()) + _int(3, 1)

        resp = _parse(self.ch.stream_unary(BS + "Write")(reqs(), timeout=3600))
        if resp.get(1, [0])[0] != size:
            raise RuntimeError(f"short write of {h}")

    def put(self, data: bytes) -> tuple[str, int]:
        h = hashlib.sha256(data).hexdigest()
        if h in self.missing([(h, len(data))]):
            self.write(h, len(data), [data[i : i + CHUNK] for i in range(0, len(data), CHUNK)] or [b""])
        return h, len(data)

    def read(self, h: str, size: int, path: Path) -> None:
        sha = hashlib.sha256()
        n = 0
        with open(path, "wb") as f:
            for resp in self.ch.unary_stream(BS + "Read")(_bytes(1, f"blobs/{h}/{size}".encode()), timeout=3600):
                data = _parse(resp).get(10, [b""])[0]
                f.write(data)
                sha.update(data)
                n += len(data)
        if n != size or sha.hexdigest() != h:
            raise RuntimeError(f"bad read of {h}")

    def get_result(self, action: tuple[str, int]) -> tuple[str, int] | None:
        try:
            r = _parse(self._unary(RE + "ActionCache/GetActionResult", _bytes(2, digest(*action))))
        except self.grpc.RpcError as e:
            if e.code() == self.grpc.StatusCode.NOT_FOUND:
                return None
            raise
        for of in r.get(2, []):  # ActionResult.output_files
            f = _parse(of)
            if f[1][0].decode() == TAR:
                return parse_digest(f[2][0])
        return None

    def set_result(self, action: tuple[str, int], tar: tuple[str, int]) -> None:
        result = _bytes(2, _bytes(1, TAR.encode()) + _bytes(2, digest(*tar)))
        self._unary(RE + "ActionCache/UpdateActionResult", _bytes(2, digest(*action)) + _bytes(3, result))


def pointer(cas: Cas, name: str) -> tuple[str, int]:
    """The Action (and its Command) whose result names the tar. Stored in CAS
    like a real action so that the entry is complete for snapshot.py."""
    command = _bytes(1, b"amphora-ccache") + _bytes(1, name.encode())
    cmd = cas.put(command)
    return cas.put(_bytes(1, digest(*cmd)) + _bytes(2, digest(EMPTY, 0)))


# --- commands -----------------------------------------------------------------


def restore(d: Path, name: str) -> None:
    cas = Cas(SOCKET)
    t = time.time()
    tar = cas.get_result(pointer(cas, name))
    if tar is None:
        print(f"ccache-cas: no stored cache for {name}; starting empty")
        return
    if cas.missing([tar]):
        print(f"ccache-cas: stored cache for {name} was expired from CAS; starting empty")
        return
    d.mkdir(parents=True, exist_ok=True)
    stamp = d / STAMP
    if stamp.is_file() and stamp.read_text().strip() == tar[0]:
        print(f"ccache-cas: {d} already holds {tar[0][:12]}")
        return
    merge = any(d.iterdir())
    with tempfile.TemporaryDirectory(prefix="ccache-cas-") as tmp:
        p = Path(tmp) / TAR
        cas.read(*tar, p)
        # Merging into a cache that is in use (dev/wine.sh): its own files win.
        subprocess.run(["tar", "-xf", str(p), "-C", str(d), "--skip-old-files", "--no-same-owner"], check=True)
    stamp.write_text(tar[0] + "\n")
    how = "merged" if merge else "restored"
    print(f"ccache-cas: {how} {tar[1] / 2**20:.0f} MiB into {d} in {time.time() - t:.1f} s")


def save(d: Path, name: str) -> None:
    if not d.is_dir():
        return
    cas = Cas(SOCKET)
    t = time.time()
    with tempfile.TemporaryDirectory(prefix="ccache-cas-") as tmp:
        p = Path(tmp) / TAR
        subprocess.run(
            ["tar", "-cf", str(p), "-C", str(d), "--sort=name", "--exclude=./tmp", f"--exclude=./{STAMP}", "--exclude=*.lock", "."],
            check=True,
        )
        sha = hashlib.sha256()
        with open(p, "rb") as f:
            while data := f.read(CHUNK):
                sha.update(data)
        tar = (sha.hexdigest(), p.stat().st_size)

        def chunks():
            with open(p, "rb") as f:
                while data := f.read(CHUNK):
                    yield data

        if cas.missing([tar]):
            cas.write(*tar, chunks())
    cas.set_result(pointer(cas, name), tar)
    (d / STAMP).write_text(tar[0] + "\n")
    print(f"ccache-cas: saved {tar[1] / 2**20:.0f} MiB from {d} in {time.time() - t:.1f} s")


def main() -> int:
    if len(sys.argv) != 4 or sys.argv[1] not in ("restore", "save"):
        print(__doc__, file=sys.stderr)
        return 2
    cmd, d, name = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
    try:
        (restore if cmd == "restore" else save)(d, name)
    except Exception as e:  # noqa: BLE001 - a cache must never fail the build
        print(f"ccache-cas: {cmd} failed, continuing without it: {e!r}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
