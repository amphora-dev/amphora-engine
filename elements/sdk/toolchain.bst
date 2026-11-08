kind: stack

description: |
  Toolchain for target builds, from the pinned buildstream-sdk junction:
  host SDK (Ubuntu 24.04), Android NDK and llvm-mingw. Elements that build
  for the device depend on this instead of naming the junction elements, so
  a toolchain bump is one edit here.

depends:
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
- filename: toolchains/android-ndk-r29.bst
  junction: buildstream-sdk.bst
- filename: toolchains/llvm-mingw-20260721-ucrt.bst
  junction: buildstream-sdk.bst
