# 缓存

Wine 是这里唯一编译时间长的元素：约 1.4 万次编译调用，冷编时 Wine 元素在 GitHub runner 上约 26 分钟，在 OrbStack amd64 上 30:23。所有缓存都在 BuildStream 自己的本地缓存（`~/.cache/buildstream`）里，没有远程缓存服务器；单次编译的缓存是 ccache，它的目录也存在 BuildStream 的 CAS 里。

| 缓存什么 | 什么时候命中 | 代价 |
|---|---|---|
| 元素产物 | 元素和它所有依赖的输入都没变 | 秒级；只重做下游，例如只改 `scripts/runtime.sh` 时只重新打包 |
| `dev/wine.sh` 的构建树（开发机） | 改普通 `.c` 后重编 | 约 10 秒（OrbStack，改一个文件）；大部分是 `bst shell` 准备沙箱和 make 走一遍 Wine 的目录树。`scripts/wine.sh` 只在 configure 的输入变了才重新 configure |
| 单次编译（ccache） | 换 Wine ref、改 `configure.ac`、换分支：元素 key 变了，但大部分 `.o` 的输入没变 | 全部命中时 Wine 元素 6:27（OrbStack，含 configure） |

开发机靠本机磁盘就够了。CI 的 runner 每次都是空的，所以要把本地缓存的一部分带到下一次运行，见下面的“CI 快照”。

## ccache 怎么接的

`bst build` 的沙箱每次都是空的，能从一次构建带到下一次的只有元素的 remote-apis socket：`wine/wine.bst` 声明 `sandbox: remote-apis-socket`，buildbox-casd 在沙箱里的 `/tmp/reapi.sock` 提供 CAS 和 action cache（`action-cache-enable-update: True` 允许写入）。整个 ccache 目录打成一个 tar 放进 CAS，用一条固定 key 的 action cache 记录指向它：

```text
Action{Command["amphora-ccache", "wine"]}  →  ActionResult{output_files: ccache.tar}
```

`tools/ccache.bst` 提供 ccache 4.14.2（静态 musl 版）和 `ccache-cas`（`scripts/ccache-cas.py`，只依赖 grpcio）。`scripts/wine.sh` 的流程：

1. 构建前 `ccache-cas restore`：把存着的 tar 解进 `/tmp/ccache`（515 MiB、2.6 万个文件，2.6 秒）。
2. 编译全部经过 ccache。
3. 结束时（构建失败也做，已经编好的结果照样有用）：
   - 整棵树从头编完且成功时，删掉这次没用到的条目（`--evict-older-than`），它们属于更早的源码，存下来的目录就一直是一次 Wine 构建的大小；
   - 这次有没命中的编译时 `ccache-cas save`（约 7 秒）；全部命中就不存，原来那份已经包含所有结果。

`AMPHORA_CCACHE` 可以改这个行为：`sync`（上面的流程，沙箱里有 socket 时的默认）、`restore`（只恢复不保存，`dev/wine.sh` 用）、`local`（不经 CAS）、`off`。

`dev/wine.sh` 的 ccache 目录在开发机本地（`~/.cache/amphora-dev/wine/ccache`）。每次构建前把 `bst build` 存下的那份合并进来（同一份只合并一次，已有的文件不覆盖），它自己的结果不回写。所以 `bst build` 之后第一次 `dev/wine.sh build` 即使要重新 configure，编译也全部命中（实测 357 秒，13933 次全中）。

**为什么换掉 recc。** recc 也是在每次编译前查缓存，但每次命中都有固定开销：先跑一遍预处理算依赖，再哈希所有输入、查 casd。同一棵树全部命中时 Wine 元素在 OrbStack 上要 15:16，ccache 是 6:27（九成以上走 direct 模式，只哈希源文件和它记下的头文件，不预处理）。

## 正确性

缓存的 key 必须包含所有会影响 `.o` 的输入，否则会拿旧的目标文件：

- **编译器本身**：ccache 默认按编译器的 mtime 和大小判断编译器有没有变，而 BuildStream 暂存的文件 mtime 都一样（2011-11-11），换了编译器也看不出来；它还只记编译器的文件名，不记路径，NDK 的 `clang` 和 llvm-mingw 的 `clang` 会被当成同一个。所以 `scripts/wine.sh` 在 `/tmp/ccache-wrap/` 给每个工具链放一个包装脚本（宿主 `gcc`/`g++`、`android-clang`/`android-clang++`、llvm-mingw 的 `clang`/`clang++`），各自设 `CCACHE_COMPILERCHECK=string:<哈希>`，哈希覆盖编译器二进制和同样决定输出的文件（gcc 的 `cc1`、`as`，llvm-mingw 的 `*.cfg`）。
- **路径**：`bst build` 的源码在 `/buildstream/amphora-engine/wine/wine.bst`，`dev/wine.sh` 的在 `/src`。`CCACHE_BASEDIR` 设为源码目录，命令行里的路径改成相对路径；Wine 本来就带 `-fdebug-compilation-dir=.`，再加 `CCACHE_NOHASHDIR=1` 不哈希当前目录。两边因此共用命中。
- **绝对路径下的头文件**（NDK sysroot、`/opt/android-sysroot`）：direct 模式的 manifest 记下每个头文件的内容哈希，换库版本就不命中。
- **目标三元组**：unix 侧 `CC` 是 `android-clang --target=aarch64-linux-android30`；`--target` 写在 `CC` 里，因为 Wine 链接时只用 `$(CC) $(LDFLAGS)`。PE 侧 Wine 直接从 PATH 调 `clang`，包装脚本目录排在 llvm-mingw 前面。
- **winebuild 的临时文件**：winebuild 把随机命名的临时 `.s` 交给编译器，direct 模式因为路径不同永远不中，preprocessed 模式按内容命中（全部命中的那次 13933 次里有 1264 次是这种）。

## CI 快照

BuildStream 的设计是：每个元素的产物都进本地 CAS，按输入算出的 key 查找；源码按 `ref` 里的 sha256 校验。所以缓存只影响快慢，不影响结果，丢了就从源码重建。CI 上只带走重建起来贵的东西：

| 进快照 | 不进快照 |
|---|---|
| 本项目元素在当前 key 下构建成功的产物（Wine 约 2 GiB、freetype、ccache、runtime） | SDK junction 的产物：宿主 SDK、NDK、llvm-mingw（约 3.4 GiB）。要用时 BuildStream 重新下载源码再导入，来源是 Google 和 GitHub Release，都按 sha256 校验 |
| 存着的 ccache 目录（一个约 0.5 GiB 的 tar，连同指向它的 action cache 记录） | 源码、构建树；构建失败的产物 |

快照放在 GitHub Actions cache，key 是 `bst-v3-<runtime.bst 的完整 key>`。runtime.bst 的 key 覆盖了整个构建的所有输入，所以：

```text
key 精确命中    → 导入，什么都不用编（runtime 产物已在快照里）
只有前缀命中    → 导入最新一份，编变了的部分；Wine 的大部分编译命中 ccache
都没有          → 冷编
main 上没精确命中 → 构建后导出并保存新快照（构建失败也存，key 加 -failed-<run>，
                    已经编好的结果下次还能用）；旧的删掉，只留最新一份
```

- 只有 main 写快照；PR 和其他分支能读 main 的，不写。
- 构建失败的产物不进快照：BuildStream 也缓存失败的构建，带过去的话，同一个 key 重跑会直接报失败，不再重试。构建失败时 `scripts/wine.sh` 照样存 ccache 目录，所以失败的那次编好的部分也带得过去。
- GitHub 每个仓库的 cache 上限 10 GB，7 天没被访问就淘汰。workflow 每周一、四定时跑一次：输入没变时精确命中、什么都不编，只为了让快照保持被访问。
- 开发机读不到 Actions cache（GitHub 没有下载接口）。要用 CI 的构建，就让 CI 把快照另外传成 workflow artifact（`bst-cache`，保留 7 天），只在要的时候传：手动跑 `gh workflow run build.yml -f upload-cache=true`，或者提交信息里写 `[upload-cache]`。本地用 `bash ci/cache/pull-ci.sh` 下载并导入（Mac 上：`GH_TOKEN=$(gh auth token) orb -m bst-amd64 bash ci/cache/pull-ci.sh`）。装了 `aria2c` 和 `unzip` 时用 16 路并发下载。输入和 CI 那次一样时 `runtime.bst` 直接是已缓存；不一样时，导入的 ccache 目录替换本机存着的那份，没变的编译照样命中。

`ci/cache/snapshot.sh`（用 BuildStream venv 的 python 跑 `snapshot.py`）：

```bash
bash ci/cache/snapshot.sh export DIR [--target runtime.bst]  # 硬链接到 DIR
bash ci/cache/snapshot.sh import DIR                         # 链回本地缓存
```

recc 时期的实测（2026-11-08，ubuntu-24.04 runner），换 ccache 后的数字待补：

| 情况 | 整个 job | `bst build` | 其中 |
|---|---|---|---|
| 冷编（没有快照） | 31:35 | 29:49 | Wine 26:12，Wine 源码 clone 约 2 分钟，SDK 下载加导入约 1 分钟，打包 1:24 |
| 精确命中 | 1:53 | 1 秒 | 恢复快照 29 秒，导入 2 秒 |
| 只改 Wine 的 key（recc 全部命中） | 11:56 | 10:29 | Wine 7:06，Wine 源码 clone 1:46，SDK 约 1 分钟，打包 1:30 |

## 不缓存的部分

ccache 统计里 1.69 万次调用有 2927 次不可缓存：链接、只预处理的调用、configure 的链接探测。imagefs 时期在 x86_64 Wine 上量过（`imagefs/docs/WINE-RECC-CACHE.md`）：这类调用加起来只占约 30 秒，缓存它们得不偿失。

## 构建日志里看命中

`scripts/wine.sh` 结束时打印 ccache 的统计和一行汇总，CI 把汇总和 `ccache-cas` 的输出提成注解，也写进 job 摘要：

```text
ccache-cas: restored 515 MiB into /tmp/ccache in 2.6 s
ccache stats: hit=13933 (direct 12669) miss=0 evicted=1260, 26103 files, 545 MiB
ccache-cas: no new compile results; the stored cache is kept
```

`direct` 是不预处理就命中的次数，`miss` 是真正编译的次数，`evicted` 是从头编完后删掉的旧条目数。
