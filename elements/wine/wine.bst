kind: manual

description: |
  Wine for the Amphora engine: Valve Proton Experimental
  (experimental-11.0-20261027b, 7b3ceaf8644b) plus Amphora's Android patch
  stack from amphora-dev/proton-wine. Unix side aarch64 Bionic (API 30,
  16 KB pages); PE side aarch64 + arm64ec (ARM64X) + i386.

  The artifact is the unstripped install tree under /opt/wine;
  runtime.bst packages the device archive from it.

depends:
- filename: sdk/toolchain.bst
  type: build
- filename: wine/host-freetype.bst
  type: build
- filename: libs/freetype.bst
  type: build
  config:
    location: /opt/android-sysroot
- filename: wine/script.bst
  type: build
- filename: tools/ccache.bst
  type: build

# Per-compile cache: Wine compiles through ccache in a directory that starts
# empty in every sandbox. scripts/wine.sh restores it from buildbox-casd's CAS
# through this socket before the build and stores it back afterwards
# (scripts/ccache-cas.py), next to the element artifacts; CI carries it between
# runs in its cache snapshot. docs/CACHE.md.
sandbox:
  remote-apis-socket:
    path: /tmp/reapi.sock
    action-cache-enable-update: True

sources:
- kind: git
  url: amphora:proton-wine.git
  track: amphora/exp-11.0-20261027b
  ref: 378407243a94290f5fc34eb93b53f0f22b1cee91
  checkout-submodules: false

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  LLVM_MINGW_ROOT: /opt/llvm-mingw
  TARGET_SYSROOT: /opt/android-sysroot
  HOST_FREETYPE: /opt/host-freetype
  # Host tools built in the tools tree (sfnt2fon) run during the target build.
  LD_LIBRARY_PATH: /opt/host-freetype/lib
  WINE_PREFIX: /opt/wine
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"

# Parallelism differs per machine (CI runner, dev VM) and does not change the
# output; keep it out of the cache key so CI's artifact is reused locally.
environment-nocache:
- JOBS

config:
  build-commands:
  - bash /opt/amphora/scripts/wine.sh build
  install-commands:
  - bash /opt/amphora/scripts/wine.sh install
  strip-commands: []
