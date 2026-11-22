kind: manual

description: |
  Device runtime archive for the Amphora SDK: the engine Wine, FEX, DXVK,
  vkd3d-proton, Turnip and FreeType, stripped, with amphora-runtime.json.
  Output under /artifacts:
  amphora-wine-<version>-<commit12>-fex-<commit7>-gfx-<graphics8>.tar.gz,
  its .sha256 and runtime.env.

depends:
- filename: sdk/toolchain.bst
  type: build
- filename: wine/wine.bst
  type: build
- filename: fex/fex.bst
  type: build
- filename: dxvk/dxvk.bst
  type: build
- filename: vkd3d-proton/vkd3d-proton.bst
  type: build
- filename: mesa/turnip.bst
  type: build
- filename: libs/freetype.bst
  type: build
  config:
    location: /opt/android-sysroot

sources:
- kind: local
  path: scripts/runtime.sh
  directory: .bst/scripts

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  LLVM_MINGW_ROOT: /opt/llvm-mingw
  TARGET_SYSROOT: /opt/android-sysroot
  WINE_ROOT: /opt/wine
  FEX_ROOT: /opt/fex
  DXVK_ROOT: /opt/dxvk
  VKD3D_ROOT: /opt/vkd3d-proton
  TURNIP_ROOT: /opt/turnip
  OUTPUT_DIR: "%{install-root}/artifacts"
  # Must match the git source ref of wine/wine.bst (BuildStream strips .git,
  # so the build cannot ask). ci/lint/check-pins.py enforces it.
  WINE_COMMIT: 770268ec7af9817b4afe2c22e3226e970e69da59
  WINE_UPSTREAM_TAG: experimental-11.0-20261027b

config:
  install-commands:
  - bash .bst/scripts/runtime.sh
  strip-commands: []
