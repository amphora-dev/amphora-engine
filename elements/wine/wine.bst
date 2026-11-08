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
- filename: tools/recc.bst
  type: build

# Per-compile cache: recc talks to buildbox-casd through this socket, so object
# files land in the local CAS/action cache next to element artifacts. CI carries
# them between runs in a GitHub Actions cache snapshot. docs/CACHE.md.
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
  RECC_SERVER: unix:/tmp/reapi.sock
  RECC_CAS_SERVER: unix:/tmp/reapi.sock
  RECC_ACTION_CACHE_SERVER: unix:/tmp/reapi.sock
  RECC_CACHE_ONLY: "1"
  # Cache-only local misses are not uploaded without this.
  RECC_CACHE_UPLOAD_LOCAL_BUILD: "1"
  RECC_USE_LOCALCAS: "1"
  # Hash headers under absolute paths too (NDK sysroot, /opt/android-sysroot).
  RECC_DEPS_GLOBAL_PATHS: "1"
  RECC_REMOTE_PLATFORM_OSFamily: linux
  RECC_REMOTE_PLATFORM_ISA: x86_64
  RECC_LOG_LEVEL: warning

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
