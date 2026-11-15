kind: manual

description: |
  FEX, the x86 translator Wine loads on ARM64: release FEX-2611.1 plus one
  fix from main (patches/). Proton's tag experimental-11.0-20261027b pins
  1c4f04b (FEX-2610-101); 2611.1 adds Windows fixes on top of it (forced
  assert, CPUID crash, disk cache hash) and is what GameNative and
  Winlator-Ludashi ship.
  Builds libarm64ecfex.dll (x86_64), libwow64fex.dll (32-bit x86) and their
  unix libraries; scripts/fex.sh.

  The artifact is the install tree under /opt/fex; runtime.bst puts the
  modules next to Wine's.

depends:
- filename: sdk/toolchain.bst
  type: build

sources:
- kind: git
  url: github:FEX-Emu/FEX.git
  track: FEX-2611.1
  ref: 4f9c1f1e36443d22d7655477e34f51b95b685bf1
  # Only what the mingw build compiles; the rest (tests, thunks, the glibc
  # allocator, profilers, disassemblers) is not fetched.
  checkout-submodules: false
  submodules:
    Source/Common/cpp-optparse:
      url: github:Sonicadvance1/cpp-optparse
      checkout: true
    External/fmt:
      url: github:fmtlib/fmt.git
      checkout: true
    External/range-v3:
      url: github:ericniebler/range-v3.git
      checkout: true
    External/rpmalloc:
      url: github:FEX-Emu/rpmalloc.git
      checkout: true
    External/unordered_dense:
      url: github:martinus/unordered_dense.git
      checkout: true
    External/xxhash:
      url: github:Cyan4973/xxHash.git
      checkout: true
# FEX's unix library on Bionic: no librt, no shm_open (the FEXTop stats
# region; the Windows side runs without it).
- kind: patch
  path: elements/fex/patches/unixlib-android.patch
# Upstream 71444c9 (main, after 2611.1): threads killed by Wine's
# NtTerminateProcess left FEX mutexes held, and the process hung on exit.
- kind: patch
  path: elements/fex/patches/wine-terminate-process-race.patch
- kind: local
  path: scripts/fex.sh
  directory: .bst/scripts

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  LLVM_MINGW_ROOT: /opt/llvm-mingw
  FEX_PREFIX: /opt/fex
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"
  # Must match the git source ref (BuildStream strips .git, so the build
  # cannot ask). ci/lint/check-pins.py enforces it. FEX_DESCRIBE is
  # `git describe --abbrev=7` of that commit, what Proton passes to FEX.
  FEX_COMMIT: 4f9c1f1e36443d22d7655477e34f51b95b685bf1
  FEX_DESCRIBE: FEX-2611.1

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/fex.sh build
  install-commands:
  - bash .bst/scripts/fex.sh install
  strip-commands: []
