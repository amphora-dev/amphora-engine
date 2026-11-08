# 从 imagefs 搬什么

> 2026-11-08 从 `amphora-dev/imagefs`（分支 `wip/engine-wine`）分出本仓库。imagefs 冻结，不再开发，旧 App 的发布链原样留着（D11：不保兼容，也不去动它）。

旧产品跑的是 Box64 里的 x86_64 Wine，imagefs 给它配 aarch64 rootfs（API 26），DXVK / vkd3d / Box64 / wrapper 各自打 WCP 发布。新引擎的 Wine unix 侧本身就是 aarch64 Bionic，所以：

- **淘汰的是组织方式**：rootfs 包（`imagefs.txz`）、WCP 打包和固定 Release、双 ABI 配方同步（`sync-arch-elements.py`）、x86_64 子图。
- **大部分组件还要**，只是目标改了：API 30（不是 26）、链进 runtime 归档；PE 组件改成 ARM64X / arm64ec + i386，版本跟 Proton tag 走。

搬的时候不整份复制：用到哪个再搬哪个，改到新目标，构建通过、上设备验证过才算搬完。

## 已搬（分仓时）

| imagefs | 本仓库 | 改动 |
|---|---|---|
| `engine/wine.bst`、`engine/wine-script.bst`、`ci/engine/wine.sh` | `wine/wine.bst`、`wine/script.bst`、`ci/wine.sh` | 只改路径 |
| `engine/runtime.bst`、`ci/engine/runtime.sh` | `runtime.bst`、`ci/runtime.sh` | 加了所有 ELF 的 16 KB 对齐检查 |
| `engine/freetype.bst` | `libs/freetype.bst` | meson profile 从 android26 改成 android30（SDK 新增 `meson-aarch64-android30.ini`） |
| `wine/host-freetype.bst`、`tools/recc.bst` | 同名 | 无 |
| `ci/setup/*`、`ci/lint/check-bst-inline-sh.py`、`.github/actions/setup-buildstream` | 同名 | 工具目录改为 `~/.cache/amphora-buildstream/tools` |
| —（imagefs 里只有注释提到） | `ci/lint/check-pins.py` | 新写：Wine commit、API 水位两处一致 |

## 以后按里程碑搬

| 组件 | imagefs 里的 | 什么时候 | 要改的 |
|---|---|---|---|
| gnutls ← nettle ← gmp | `crypto/*` | 现在就缺（`bcrypt` 报 no encryption support） | API 30；Wine 去掉 `--without-gnutls` |
| zlib、zstd、brotli、libpng、libffi、libexpat、pcre2、libiconv、glib | `compress/*`、`text/*` | 跟着 GStreamer / fontconfig 一起 | 只搬依赖链上真用到的 |
| GStreamer、gst-plugins-base | `media/*` | 媒体解码（贴近 Proton 的 winegstreamer） | 插件集合按 Proton 定，不止 base |
| fontconfig | `text/fontconfig.bst` | 需要找系统字体时；Wine 现在 `--without-fontconfig` | 可能用不上 |
| SDL2 | `media/sdl2.bst` | 手柄方案定了以后（winebus） | 输入可能改由宿主转发，到时再定 |
| 音频 | `audio/alsa-lib.bst`、`alsa-android-aserver.bst` | 音频方案定了以后 | 新设计倾向宿主侧 AAudio，ALSA 不一定要 |
| vulkan-headers、vulkan-loader | `graphics/*` | M3 | M3 决定 Wine 直接加载 Turnip 还是经 loader |
| DXVK | `l1/dxvk-wcp.bst`、`ci/dxvk/` | M3 | ARM64X + i386；版本按 Proton tag（Experimental：`a78a467ca`）；不带 gplasync，也不带 Sarek；不打 WCP |
| vkd3d-proton | `l1/vkd3d-wcp.bst`、`ci/vkd3d/` | M3 | 同上（`cae2e003b`） |
| Mesa WGL（Zink） | `l1/mesa-wgl.bst`、`ci/mesa-wgl/` | M3 | 改成 arm64ec + i386 PE |
| glslang（宿主） | `host/glslang.bst` | 跟 DXVK / vkd3d 一起 | 无 |
| Turnip | 不在 imagefs（`amphora-turnip`） | M3 | 改成普通 Vulkan ICD（D14 相关，12 §3.1） |

## 不搬

| imagefs 里的 | 为什么 |
|---|---|
| `l1/box64-wcp.bst`、`vendor/box64-patches` | D5：不要 Box64 |
| `l1/wrapper-tzst.bst`、`vendor/wrapper-patches`、`graphics/mesa-gl.bst`、`vendor/mesa-gl-patches` | 不要 wrapper / adrenotools；原生 Bionic GL 是给 X11 路径用的 |
| `l1/proton-wine-wcp.bst`、`wine/x86_64/*`、`wine/sysroot-x86_64.bst`、`wine/prefix-pack-x86_64.bst`、`vendor/proton-prefix` | x86_64 Wine；前缀改为薄前缀模板（D13） |
| `l1/dxvk-d3d89-wcp.bst` | 只是绕开高通系统驱动不认固定功能着色器的问题；新设计默认 Turnip。M3 矩阵真复现了再加 |
| `x11/*` | 没有 X，出画走 wineandroid.drv |
| `android/*`（sysvshm、shmem、spawn、sysv-semaphore、libcxx-shared） | 给旧 rootfs 里的程序补 libc 缺口；新 Wine 没用到。哪个库真要了再说 |
| `imagefs/*`、`tests/*`、`recipes/`、`sync-arch-elements.py` | rootfs 打包和双 ABI 同步 |
| `ci/gate`、`ci/publish`、`ci/verify`、`.github/actions/bump-manifest`、8 条构建 workflow | WCP 发布链；本仓库的发布等 runtime 格式和 content_manifest 的新格式定了再写 |
| `vendor/winlator-bionic`、`crypto/openssl.bst` | 旧产品专用 |
