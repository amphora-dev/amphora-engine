kind: manual

description: |
  Device runtime archive for the Amphora SDK: the engine Wine plus FreeType,
  stripped, with amphora-runtime.json. Output under /artifacts:
  amphora-wine-<version>-<commit12>.tar.gz, its .sha256 and runtime.env.

depends:
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
  type: build
- filename: toolchains/android-ndk-r29.bst
  junction: buildstream-sdk.bst
  type: build
- filename: toolchains/llvm-mingw-20260721-ucrt.bst
  junction: buildstream-sdk.bst
  type: build
- filename: wine/wine.bst
  type: build
- filename: libs/freetype.bst
  type: build
  config:
    location: /opt/android-sysroot

sources:
- kind: local
  path: ci/runtime.sh
  directory: .bst/ci

environment:
  TARGET_TRIPLE: "%{target-triple}"
  ANDROID_NDK_HOME: "%{ndk-root}"
  LLVM_MINGW_ROOT: /opt/llvm-mingw
  TARGET_SYSROOT: /opt/android-sysroot
  WINE_ROOT: /opt/wine
  OUTPUT_DIR: "%{install-root}/artifacts"
  # Must match the git source ref of wine/wine.bst (BuildStream strips .git,
  # so the build cannot ask). ci/lint/check-pins.py enforces it.
  WINE_COMMIT: 378407243a94290f5fc34eb93b53f0f22b1cee91
  WINE_UPSTREAM_TAG: experimental-11.0-20261027b

config:
  install-commands:
  - bash .bst/ci/runtime.sh
  strip-commands: []
