kind: manual

description: |
  ccache 4.14.2 (static musl build) for Wine's per-compile cache, plus
  ccache-cas (scripts/ccache-cas.py), which keeps the ccache directory in
  buildbox-casd's CAS between builds through the sandbox remote-apis socket.
  ccache-cas needs grpcio; 1.74.0 is the last release without a
  typing-extensions requirement, which the host SDK's python does not have.

depends:
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
  type: build

sources:
- kind: remote
  url: ccache:v4.14.2/ccache-4.14.2-linux-x86_64-musl-static.tar.xz
  ref: b20ff6415151226ac5a10dfd6839700c694bd67d1871c8fddb266d366ff25bfb
  filename: ccache.tar.xz
- kind: remote
  url: pypi:9d/2c/930b0e7a2f1029bbc193443c7bc4dc2a46fedb0203c8793dcd97081f1520/grpcio-1.74.0-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl
  ref: 176d60a5168d7948539def20b2a3adcce67d72454d9ae05969a2e73f3a0feee7
  filename: grpcio.whl
- kind: local
  path: scripts/ccache-cas.py

config:
  install-commands:
  - |
    set -eu
    mkdir -p "%{install-root}/usr/bin" "%{install-root}/usr/lib/ccache-cas"
    tar --no-same-owner -xJf ccache.tar.xz --strip-components=1 -C "%{install-root}/usr/bin" ccache-4.14.2-linux-x86_64-musl-static/ccache
    python3 -m zipfile -e grpcio.whl "%{install-root}/usr/lib/ccache-cas"
    install -m 0755 ccache-cas.py "%{install-root}/usr/bin/ccache-cas"
    "%{install-root}/usr/bin/ccache" --version >/dev/null
    PYTHONDONTWRITEBYTECODE=1 python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); import grpc' "%{install-root}/usr/lib/ccache-cas"

  strip-commands: []
