kind: meson

description: |
  FreeType 2.13.3 for the engine's Wine (aarch64 Bionic, API 30). Wine only
  needs TrueType/OpenType rendering, so every optional dependency is off and
  the runtime ships a single libfreetype.so.

depends:
- filename: profiles/android-cross-files.bst
  junction: buildstream-sdk.bst
  type: build
  config:
    location: /opt/amphora-sdk/profiles
- filename: host/noble-amd64.bst
  junction: buildstream-sdk.bst
  type: build
- filename: toolchains/android-ndk-r29.bst
  junction: buildstream-sdk.bst
  type: build

sources:
- kind: tar
  url: freetype:freetype-2.13.3.tar.xz
  ref: 0550350666d427c74daeb85d5ac7bb353acba5f76956395995311a9c6f063289

variables:
  meson-local: >-
    -Dbrotli=disabled
    -Dbzip2=disabled
    -Dharfbuzz=disabled
    -Dpng=disabled
    -Dzlib=disabled
    -Dtests=disabled

config:
  strip-commands:
  - |
    find "%{install-root}%{prefix}/lib" -type f -name 'libfreetype.so*' \
      -exec "$STRIP" {} +
