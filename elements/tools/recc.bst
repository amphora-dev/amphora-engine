kind: manual

description: |
  BuildGrid recc 1.4.25 — Remote Execution Caching Compiler (cache-only
  against the BuildStream/buildbox-casd remote-apis socket).

depends:
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
  type: build

sources:
- kind: remote
  url: buildbox:1.4.25/recc-1.4.25-x86_64-linux-gnu.tgz
  ref: 2cbdd301b622dd932600d79232d60157127d64940dc3e2211fcdc55db23614f7
  filename: recc-1.4.25-x86_64-linux-gnu.tgz

config:
  install-commands:
  - |
    set -eu
    mkdir -p "%{install-root}/usr/bin"
    tar -xzf recc-1.4.25-x86_64-linux-gnu.tgz -C "%{install-root}/usr/bin"
    chmod +x "%{install-root}/usr/bin/recc"
    "%{install-root}/usr/bin/recc" --help >/dev/null

  strip-commands: []
