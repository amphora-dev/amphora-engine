kind: manual

description: |
  vkd3d-proton (Direct3D 12 on Vulkan) at the commit Proton's tag
  experimental-11.0-20261027b pins: cae2e00 (seven commits before v3.1),
  built the way Proton's Makefile.in builds it (scripts/d3d.sh): 32-bit
  x86 and ARM64EC.

  The artifact is the install tree under /opt/vkd3d-proton, laid out as in
  Proton: lib/wine/vkd3d-proton/{aarch64,i386}-windows.

depends:
- filename: sdk/toolchain.bst
  type: build
- filename: tools/glslang.bst
  type: build

sources:
- kind: git
  url: github:HansKristian-Work/vkd3d-proton.git
  track: master
  ref: cae2e003bb8251627ff93c0f471ae18a28234490
  submodules:
    subprojects/dxil-spirv:
      url: github:HansKristian-Work/dxil-spirv
    khronos/Vulkan-Headers:
      url: github:KhronosGroup/Vulkan-Headers
    khronos/SPIRV-Headers:
      url: github:KhronosGroup/SPIRV-Headers
# dxil-spirv's own submodules that the build reads (the git source does not
# recurse); SPIRV-Tools and SPIRV-Cross are only for its tests.
- kind: git
  url: github:KhronosGroup/SPIRV-Headers.git
  ref: c63848ecf2200425511319fd8bf2c17b751e501e
  directory: subprojects/dxil-spirv/third_party/spirv-headers
- kind: git
  url: github:doitsujin/dxbc-spirv.git
  ref: 8dae2d8573af08378c6059aca3d5987da99d20b5
  checkout-submodules: false
  directory: subprojects/dxil-spirv/subprojects/dxbc-spirv
- kind: local
  path: scripts/d3d.sh
  directory: .bst/scripts

environment:
  LLVM_MINGW_ROOT: /opt/llvm-mingw
  D3D_PREFIX: /opt/vkd3d-proton
  INSTALL_ROOT: "%{install-root}"
  JOBS: "%{max-jobs}"
  # Must match the git source ref; ci/lint/check-pins.py enforces it.
  # VKD3D_BUILD and VKD3D_DESCRIBE are what Proton writes into vkd3d_build.h
  # and vkd3d_version.h: `git describe --always --exclude='*' --abbrev=15`
  # and `git describe --always --tags` of that commit.
  VKD3D_COMMIT: cae2e003bb8251627ff93c0f471ae18a28234490
  VKD3D_BUILD: cae2e003bb82516
  VKD3D_DESCRIBE: v3.0.1-477-gcae2e003

environment-nocache:
- JOBS

config:
  build-commands:
  - bash .bst/scripts/d3d.sh vkd3d-proton build
  install-commands:
  - bash .bst/scripts/d3d.sh vkd3d-proton install
  strip-commands: []
