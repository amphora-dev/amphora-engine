kind: manual

description: |
  DXVK (Direct3D 8 to 11 on Vulkan) at the commit Proton's tag
  experimental-11.0-20261027b pins: a78a467 (v3.1.1-97), built the way
  Proton's Makefile.in builds it (scripts/d3d.sh): 32-bit x86 and ARM64EC.

  The artifact is the install tree under /opt/dxvk, laid out as in Proton:
  lib/wine/dxvk/{aarch64,i386}-windows.

depends:
- filename: sdk/toolchain.bst
  type: build
- filename: tools/glslang.bst
  type: build

sources:
- kind: git
  url: github:doitsujin/dxvk.git
  track: master
  ref: a78a467cadb22bee928904290cf8e7921b121851
  submodules:
    include/native/directx:
      url: github:Joshua-Ashton/mingw-directx-headers
    include/vulkan:
      url: github:KhronosGroup/Vulkan-Headers
    include/spirv:
      url: github:KhronosGroup/SPIRV-Headers.git
    subprojects/libdisplay-info:
      url: github:doitsujin/libdisplay-info.git
    subprojects/dxbc-spirv:
      url: github:doitsujin/dxbc-spirv.git
# dxbc-spirv's own submodule (the git source does not recurse).
- kind: git
  url: github:KhronosGroup/SPIRV-Headers.git
  ref: c8ad050fcb29e42a2f57d9f59e97488f465c436d
  directory: subprojects/dxbc-spirv/submodules/spirv_headers
- kind: local
  path: scripts/d3d.sh
  directory: .bst/scripts

environment:
  LLVM_MINGW_ROOT: /opt/llvm-mingw
  D3D_PREFIX: /opt/dxvk
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"
  # Must match the git source ref (BuildStream strips .git, so the build
  # cannot ask). ci/lint/check-pins.py enforces it. DXVK_DESCRIBE is
  # `git describe --always --abbrev=15` of that commit, what Proton writes
  # into version.h.
  DXVK_COMMIT: a78a467cadb22bee928904290cf8e7921b121851
  DXVK_DESCRIBE: v3.1.1-97-ga78a467cadb22be

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/d3d.sh dxvk build
  install-commands:
  - bash .bst/scripts/d3d.sh dxvk install
  strip-commands: []
