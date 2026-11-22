# amphora-engine

Amphora 引擎设备端运行时的构建项目：从源码构建 Wine（Valve Proton Experimental + 我们的补丁）、x86 翻译器 FEX、Direct3D 翻译层（DXVK、vkd3d-proton）、GPU 驱动 Turnip 和它们在 Android 上要的原生库，打成 SDK 安装的 runtime 归档。只用 BuildStream 构建。

设计和进度在 [`amphora-dev/amphora`](https://github.com/amphora-dev/amphora)（本地 `~/co/github/amphora-steam`）：决策见其 `docs/research/12-REWRITE-DESIGN.md`，进度见 `docs/TRACKING.md`。旧产品（x86_64 Wine + Box64、imagefs rootfs、WCP 发布）的构建留在 [`amphora-dev/imagefs`](https://github.com/amphora-dev/imagefs)，不再开发；从那里搬什么、怎么改，见 [`docs/FROM-IMAGEFS.md`](docs/FROM-IMAGEFS.md)。

## 产物

`runtime.bst` → `/artifacts/`：

- `amphora-wine-<version>-<commit12>-fex-<FEX commit7>-gfx-<graphics8>.tar.gz`：设备上的 runtime 根目录，带 `amphora-runtime.json`（SDK 安装器读这个）。`<graphics8>` 是 DXVK commit、vkd3d-proton commit、Mesa 版本和补丁合起来的哈希：Release 以归档名命名，配方按名字和 sha256 钉住它，所以内容变了名字就得变
- 同名 `.sha256`，以及 `runtime.env`（名字、sha256、大小，给 CI 和 manifest 用）

目标统一：aarch64 Bionic，**API 30**，16 KB 页；Wine 的 PE 侧是 ARM64X（aarch64 + arm64ec）+ i386。FEX 用正式发布版（现在是 FEX-2611.1，比 Proton tag 里钉的 `1c4f04b` 多了几处 Windows 修复，另带一个 main 上的修复），和 Proton 一样构建 `libarm64ecfex.dll`（64 位 x86）、`libwow64fex.dll`（32 位 x86）和它们的 unix 库，放在 Wine 的模块旁边；配置默认值是 Proton 的 `FEX_Config.json`（`share/fex-emu/Config.json`）。

图形栈（都在 runtime 里，SDK 不再单独下载任何东西）：

- **DXVK、vkd3d-proton**：Proton tag 的子模块提交（`a78a467`、`cae2e00`），照 Proton 的 `Makefile.in` 构建（meson、`buildtype=plain`、同样的编译参数、同一个 glslang），布局也照 Proton：`lib/wine/dxvk/{aarch64,i386}-windows`、`lib/wine/vkd3d-proton/…`。SDK 把它们链进前缀的 `system32` / `syswow64`。**和 tag 的一处差别**：64 位文件是 ARM64EC，不是 ARM64X。ARM64X 要用 Valve 自己构建的 llvm-mingw（同一个版本，加 13 个 LLVM 补丁，C 运行库也按 ARM64X 重编，见 Proton 的 `docker/`）；我们用的上游发布版的 C 运行库只有 ARM64EC 一半，链不出 ARM64X。Proton 11.0 稳定版的 ARM64 构建发的也是 ARM64EC。x86_64 程序两种都按原生速度加载，只有本身是 ARM64 的 Windows 程序用不了。
- **Turnip**：Mesa 最新稳定版（现在 26.3.1）的 Adreno Vulkan 驱动，只带 KGSL 后端，按 Android 的 Vulkan HAL 模块构建成 `lib/libvulkan_freedreno.so`。Wine 的显示驱动直接打开它（`WINE_ANDROID_VULKAN_HAL`），不经系统的 `libvulkan.so`、wrapper 或 adrenotools。Proton 不钉 Mesa（SteamOS 自带），所以这一项跟 Mesa 的发布走。带一个补丁（`elements/mesa/patches/`）：高通新的 gralloc 不再写 `gmsm` 标记，Mesa 读不到 AHardwareBuffer 的 UBWC 标志。

## 元素

```text
runtime.bst                 打包、strip、校验、写 manifest（scripts/runtime.sh）
├── wine/wine.bst           Wine 本体（scripts/wine.sh），产物是未 strip 的 /opt/wine
│   ├── wine/script.bst     scripts/wine.sh（单独成元素）
│   ├── wine/host-freetype  构建期工具 sfnt2fon 用的宿主 FreeType
│   ├── libs/freetype.bst   目标 FreeType（Wine 只链它）
│   └── tools/ccache.bst    ccache 和 ccache-cas：单次编译缓存（docs/CACHE.md）
├── fex/fex.bst             FEX 的 Wine 模块（scripts/fex.sh），产物是 /opt/fex；
│                           fex/patches/：unix 库在 Bionic 上没有 librt 和 shm_open；
│                           上游 main 的 71444c9（进程退出时卡死）
├── dxvk/dxvk.bst           DXVK（scripts/d3d.sh），产物是 /opt/dxvk
├── vkd3d-proton/vkd3d-proton.bst   vkd3d-proton（同一个脚本），产物是 /opt/vkd3d-proton
│   └── tools/glslang.bst   Proton tag 钉的 glslang（宿主工具），两者编译着色器用
├── mesa/turnip.bst         Turnip（scripts/turnip.sh），产物是 /opt/turnip；mesa/patches/
│   └── mesa/glslang.bst    glslang 16.5.0（宿主工具）：Mesa 要 12.2 以上，Proton 钉的那个太旧
├── libs/freetype.bst
└── sdk/toolchain.bst       stack：宿主 SDK + NDK r29 + llvm-mingw（换版本只改这里）
buildstream-sdk.bst         junction：上面三样和 meson profile
```

新库放 `libs/`，按里程碑加，跟着第一个用到它的元素进来（`project.conf` 的 alias 也一样）。

## 本地构建

需要 x86_64 Linux（宿主 SDK 是 Ubuntu Noble amd64）。Mac 上用 OrbStack 的 amd64 机器 `bst-amd64`，仓库目录直接挂进去。

```bash
sudo apt-get install bubblewrap fuse3 git lzip patch python3-venv xz-utils
bash ci/setup/install-buildstream.sh

./bst build runtime.bst
./bst artifact checkout runtime.bst --directory out/runtime
```

**没推送的提交**：Wine 分支和 SDK 分支在推到 GitHub 之前，用本地镜像构建。`~/.config/buildstream.conf`：

```yaml
projects:
  amphora-engine:
    mirrors:
    - name: local
      aliases:
        amphora:
        - file:///Users/sky/.cache/amphora-mirrors/
    default-mirror: local
```

改 Wine 源码用 `dev/wine.sh`，不用 BuildStream workspace（workspace 每次都要把整棵构建树重新存进 CAS，慢）：

```bash
dev/wine.sh build     # 在 wine.bst 自己的构建沙箱里增量编译；源码默认是旁边的 ../wine-arm64ec（WINE_SRC 可改）
dev/wine.sh mark      # 记下时间点
dev/wine.sh changed   # 列出之后变了的、要推到设备上的文件
dev/push.sh           # 在有 adb 的机器（Mac）上跑：把这些文件换进设备上已装的 runtime；也可以只给几个 runtime 路径
```

`dev/push.sh` 只用于开发：换过文件的 runtime 不再对应任何配方，要回到发布版就在 App 的系统页重装 runtime。它在推之前检查文件不是全零、PE 文件有 MZ 头（本地 `bst build` 出过内容全零的 i386 PE 文件，见 amphora-steam 的 `docs/TRACKING.md`）。

它把 `WINE_SRC` 同步到 `~/.cache/amphora-dev/wine/src`，构建树在旁边的 `build/`，ccache 目录在 `ccache/`；每次构建前先并入最近一次 `bst build` 存下的 ccache（同一份只并一次），所以第一次也几乎全部命中。之后改一个 `.c` 约 10 秒。要先 `./bst build runtime.bst` 一次（或 `ci/cache/pull-ci.sh`），让 wine.bst 的构建依赖都在缓存里。

## 缓存

都在 BuildStream 的本地缓存里：元素产物，和 Wine 的 ccache 目录（整个目录打成一个 tar，经沙箱里的 `remote-apis-socket` 存进 CAS）。没有远程缓存服务器。CI 把本项目的元素产物和这份 ccache 存成 GitHub Actions cache 快照，下一次运行导入；SDK 不进快照，要用时重新下载。细节和数字见 [`docs/CACHE.md`](docs/CACHE.md)。

## 约定

- 元素里的 `*-commands` 由 `sh -c -e` 跑，SDK 的 `/bin/sh` 是 dash：inline 只写 POSIX sh，长逻辑放 `scripts/*.sh`（沙箱里跑的构建脚本；`ci/` 只放宿主上跑的 CI 工具）。`ci/lint/check-bst-inline-sh.py` 检查。
- API 水位只在 `project.conf` 的 `target-triple` 写一次，Wine 和 manifest 的 minSdk 都从它来；Wine、FEX、DXVK、vkd3d-proton 的 commit 和版本字符串各写在两处（BuildStream 不保留 `.git`），由 `ci/lint/check-pins.py` 对齐。
- 不在 BuildStream 外维护平行的构建配方、共享 staging 或完成标记。ccache 只在沙箱里用，它的目录也存在 BuildStream 的 CAS 里，不挂沙箱外的目录（`dev/wine.sh` 除外，它本来就不是发布路径）。
