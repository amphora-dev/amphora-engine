# AGENTS.md

Amphora 设备端 runtime 的构建项目：用 BuildStream 构建 Wine 和 FEX，打成 SDK 安装的 runtime 归档。设计和进度在 `../amphora-steam`（`docs/TRACKING.md`、`docs/research/12-REWRITE-DESIGN.md`）；本仓库的细节见 `README.md`、`docs/CACHE.md`、`docs/FROM-IMAGEFS.md`。

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
```

要先 `./bst build runtime.bst` 或 `ci/cache/pull-ci.sh` 一次。Wine 的提交信息照上游风格写（`ntdll: Do X.`）；推到 `amphora-dev/proton-wine` 之前，本地构建要靠 `~/.config/buildstream.conf` 里的本地镜像（见 README）。

## 发布

- 正式 runtime **只由 CI 构建**（`.github/workflows/build.yml`，main 上发 Release）。本地 VM 构建出过 481 个内容全为 0 的 i386 DLL，原因没查；本地产物不要装到设备上。
- 升级 Wine 或 FEX：改 source `ref`，同时改重复写的值，即 `runtime.bst` 的 `WINE_COMMIT`，以及 `fex/fex.bst` 的 `FEX_COMMIT`、`FEX_DESCRIBE`。`ci/lint/check-pins.py` 会检查这几处是否一致。
- Release 出来后，在 `amphora-steam` 的 `sdk/src/main/assets/amphora/recipe.json` 按 `runtime.env` 更新配方。

## 检查（同 `.github/workflows/lint.yml`）

```bash
shellcheck -S warning $(git ls-files '*.sh')
python3 ci/lint/check-bst-inline-sh.py
python3 ci/lint/check-pins.py
```

## 约定

- 元素里的 `*-commands` 由 dash 执行，inline 只写 POSIX sh；长逻辑放 `scripts/*.sh`（沙箱里跑）。`ci/` 只放宿主上跑的工具。
- API 水位只写在 `project.conf` 的 `target-triple`（API 30）；所有 ELF 要 16 KB 页对齐。
- 新库放 `elements/libs/`，跟着第一个用到它的里程碑加。
- 不在 BuildStream 外维护平行的构建配方；ccache 目录只存在 BuildStream 的 CAS 里（`dev/wine.sh` 除外）。
- 提交信息：`<范围>: <说明>`，范围如 `wine`、`fex`、`build`、`docs`、`dev/wine.sh`。
