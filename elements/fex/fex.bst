kind: manual

description: |
  FEX, the x86 translator Wine loads on ARM64, at the commit Proton pins for
  the Wine tag we follow (Proton experimental-11.0-20261027b, submodule FEX:
  1c4f04b, FEX-2610-101). Nothing newer and no fixes from FEX's main on top:
  what runs here is what runs on Steam, so a problem can be compared with
  one there. A fix goes in as a patch once a test on the device shows the
  problem it fixes.
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
  track: main
  ref: 1c4f04b71a4d33091183fd7e1a2c09e6823d27fd
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
  FEX_COMMIT: 1c4f04b71a4d33091183fd7e1a2c09e6823d27fd
  FEX_DESCRIBE: FEX-2610-101-g1c4f04b

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/fex.sh build
  install-commands:
  - bash .bst/scripts/fex.sh install
  strip-commands: []
