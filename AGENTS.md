# AGENTS.md

Amphora 设备端 runtime 的构建项目：用 BuildStream 构建 Wine、FEX、DXVK、vkd3d-proton 和 Turnip，打成 SDK 安装的 runtime 归档。设计和进度在 `../amphora-steam`（`docs/TRACKING.md`、`docs/research/12-REWRITE-DESIGN.md`）；本仓库的细节见 `README.md`、`docs/CACHE.md`、`docs/FROM-IMAGEFS.md`。

## 在哪里跑

BuildStream 要 x86_64 Linux。Mac 上用 OrbStack 的 amd64 机器 `bst-amd64`，仓库路径和 Mac 上相同：

```bash
orb -m bst-amd64 ./bst build runtime.bst
orb -m bst-amd64 ./bst artifact checkout runtime.bst --directory out/runtime
GH_TOKEN=$(gh auth token) orb -m bst-amd64 bash ci/cache/pull-ci.sh   # 导入 CI 的构建缓存；要在本仓库根目录跑
```

## 改 Wine

Wine 源码在 `../wine-arm64ec`（分支 `amphora/exp-11.0-20261027b`）。日常改动用 `dev/wine.sh`，不用 BuildStream workspace：

```bash
orb -m bst-amd64 dev/wine.sh mark
orb -m bst-amd64 dev/wine.sh build     # 增量编译，改一个 .c 约 10 秒
orb -m bst-amd64 dev/wine.sh changed   # 要推到设备上的文件
ANDROID_SERIAL=HA262AAH dev/push.sh    # 在 Mac 上跑：把它们换进设备上已装的 runtime（只用于开发）
ANDROID_SERIAL=HA262AAH dev/push.sh --tree <目录>   # 别的元素的产物（DXVK、Turnip）：目录按 runtime 的布局摆好
```

要先 `./bst build runtime.bst` 或 `ci/cache/pull-ci.sh` 一次。Wine 的提交信息照上游风格写（`ntdll: Do X.`）；推到 `amphora-dev/proton-wine` 之前，本地构建要靠 `~/.config/buildstream.conf` 里的本地镜像（见 README）。

## 发布

- 正式 runtime **只由 CI 构建**（`.github/workflows/build.yml`，main 上发 Release）。本地 VM 构建出过 481 个内容全为 0 的 i386 DLL，原因没查；本地产物不要装到设备上。
- 升级 Wine 或 FEX：改 source `ref`，同时改重复写的值，即 `runtime.bst` 的 `WINE_COMMIT`，以及 `fex/fex.bst` 的 `FEX_COMMIT`、`FEX_DESCRIBE`。`ci/lint/check-pins.py` 会检查这几处是否一致。
- 升级 DXVK 或 vkd3d-proton（跟 Proton tag 的子模块走）：改 source `ref` 和元素里的 `DXVK_COMMIT` / `DXVK_DESCRIBE`、`VKD3D_COMMIT` / `VKD3D_BUILD` / `VKD3D_DESCRIBE`（怎么得到这些值写在元素的注释里）；子模块的 commit 也要跟着对（嵌套的子模块是单独的 git source）。升级 Mesa：改 tarball、sha256 和 `MESA_VERSION`，看 `elements/mesa/patches/` 里的补丁上游有没有了。
- DXVK、vkd3d-proton 的 64 位文件现在是 ARM64EC 而不是 Proton tag 的 ARM64X（要 Valve 打过补丁的 llvm-mingw，见 README）。
- Release 出来后，在 `amphora-steam` 的 `sdk/src/main/assets/amphora/recipe.json` 按 `runtime.env` 更新配方。

## 检查（同 `.github/workflows/lint.yml`）

```bash
mapfile -t scripts < <(find . -name '*.sh' -not -path './.git/*' | sort)
shellcheck -S warning -f gcc "${scripts[@]}"
find . -name '*.sh' -not -path './.git/*' -print0 | xargs -0 -n1 bash -n
find . -name '*.py' -not -path './.git/*' -print0 | xargs -0 python3 -m py_compile
test -x bst
python3 ci/lint/check-bst-inline-sh.py   # 要 pyyaml
python3 ci/lint/check-pins.py
```

## 约定

- 元素里的 `*-commands` 由 dash 执行，inline 只写 POSIX sh；长逻辑放 `scripts/*.sh`（沙箱里跑）。`ci/` 只放宿主上跑的工具。
- API 水位只写在 `project.conf` 的 `target-triple`（API 30）；所有 ELF 要 16 KB 页对齐。
- 新库放 `elements/libs/`，跟着第一个用到它的里程碑加。
- 不在 BuildStream 外维护平行的构建配方；ccache 目录只存在 BuildStream 的 CAS 里（`dev/wine.sh` 除外）。
- 提交信息：`<范围>: <说明>`，范围如 `wine`、`fex`、`build`、`docs`、`dev/wine.sh`。
