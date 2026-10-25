# A17 上的 turnip：用 meson2hermetic 在 mesa 26.1 上重新生成

起草 2026-10-25（a17-migration-plan.md 第 6 节 M6「mesa 路线 B」）。状态：**生成管线已在构建机副本上跑通并自检全过；还没有 `m` 过**（见第 6 节）。

一句话：A17 的 `external/mesa3d` 是 26.1.0-devel，旧生成器 `meson_to_hermetic` 删了。我们用上游的新生成器 meson2hermetic（`meson convert`）把整棵 mesa 重新生成一遍，配置在上游 Android 那份的基础上加一个 turnip 配置。直接产出 `cc_library_shared "vulkan.freedreno"`，A16 那套 12 个坑里绝大多数不用再修。

```bash
# 构建机上（不跑 m；约 20 秒）。先在副本上跑：
# 目标目录必须先不存在，否则 cp -a 会拷成 mesa3d/mesa3d、在旧副本上接着跑
rm -rf ~/a17-mesa-work/mesa3d && mkdir -p ~/a17-mesa-work &&
  cp -a ~/crdroid/external/mesa3d ~/a17-mesa-work/mesa3d && rm ~/a17-mesa-work/mesa3d/.git   # .git 是 repo 的软链
bash scripts/mesa-a17/regen.sh ~/a17-mesa-work/mesa3d --tree ~/crdroid --export ~/a17-mesa-work/turnip-a17-bp.tar.gz
# 确认无误后改真树（脚本默认拒绝碰 ~/crdroid）：
bash scripts/mesa-a17/regen.sh ~/crdroid/external/mesa3d --allow-crdroid-tree --tree ~/crdroid
# 然后（D16 以上）：
m vulkan.freedreno
```

## 1. A17 的 mesa 里有什么（已核实）

| 事实 | 出处 |
|---|---|
| `VERSION` = `26.1.0-devel`。HEAD 是 `875160ed32c`，"Snap for 15081330 … to 26Q2-release"，快照时间 2026-03 | 构建机 `~/crdroid/external/mesa3d`（`git log -1`） |
| 旧的 `meson_to_hermetic/`（含 `aosp.toml`、`build-android-turnip.sh`）被 `7d26db2ca2a` "nuke old build rules" 删掉。`34538425e1f` "autogenerate Android.bp files using meson2hermetic" 换成 90 个按目录拆开的 `Android.bp` | 同上，`git show --stat` |
| 生成命令写在 `README.aosp.md:7-13`：`python3 ~/meson/meson.py convert android aosp_mesa3d`，生成器是 `gurchetansingh/mesonbuild` 的 `meson2hermetic` 分支（meson PR #15462，未合并） | `refs/a17/external/mesa3d/README.aosp.md` |
| **树里没有配置文件**。快捷写法要 `hermetic/android/{aosp_mesa3d,platforms,dependencies}.toml`（生成器 `mesonbuild/hermetic/hermetic_projects.py:24-30`），A17 树里没有 `hermetic/`。上游 mesa 到 MR !42932（2026-07-16 合入）才把这几个文件放进 `src/gfxstream/hermetic/android/`，晚于 A17 的快照 | 构建机 `git ls-tree`；GitLab API |
| 现成的 Android.bp 只有 gfxstream（`vulkan.ranchu`）和 lavapipe（`vulkan.lvp`）。**没有 freedreno / turnip**，`src/freedreno/**` 下一个 Android.bp 都没有 | `refs/a17/external/mesa3d`（`grep -rl freedreno --include=Android.bp` 为空） |
| 根 `Android.bp:518-701` 是 gfxstream / goldfish 的**手写兼容块**（`mesa_platform_virtgpu*`、`mesa_gfxstream_*` 等），被 `device/generic/goldfish`、`hardware/google/gfxstream` 按名引用 | `refs/a17/external/mesa3d/Android.bp:518-532` 注释 |
| turnip 的 ANB 延迟绑定在 26.1 里仍然没实现：`tu_image.cc:1013` 还是 `/* TODO handle VkNativeBufferANDROID */` + `UNREACHABLE` | `refs/a17/external/mesa3d/src/freedreno/vulkan/tu_image.cc:1011-1015` |
| 上游后来自己接入了 turnip：MR !41518（2026-05-18 合入）"Enable vulkan.freedreno in Android build system using meson2hermetic" 修了 6 处 meson / 编译问题；上游配置里有 `aosp_reference_embedded_drivers`（freedreno，`msm,kgsl`）。**这两样都在 A17 快照之后** | GitLab MR !41518、`src/gfxstream/hermetic/android/aosp_mesa3d.toml@main` |

## 2. 选哪条路

任务给了两个选项：(i) 扩展上游的 hermetic 配置，加上 turnip；(ii) 自己拿一份 turnip 配置跑 meson2hermetic。实际做法是两者合一：**自己跑生成器（ii），配置用上游那份再加一个 turnip 配置（i）**，一次重新生成整棵树。理由：

* (i) 没法"只扩展"：A17 树里根本没有配置可扩展（见上表），只能从上游 main 取回来。
* 只生成 turnip、再合进现有 Android.bp 行不通。turnip 要用的 `mesa_util`、`vulkan_runtime`、`nir`、`compiler`……和 A17 现成的模块**同名**，这正是 A16 坑 C2 的重演，只能改名或者剔除。而生成器本来就是为"多个配置合并成一套 `select()`"设计的：同一平台上几个配置的属性取并集（实测 `_mesa_u_gralloc` 的 `-DHAS_FREEDRENO` 只出现在 `("arm64","android")` 分支）。把 turnip 当成第 N 个配置一起生成，名字天然一致。
* 代价：gfxstream / lavapipe 那部分也跟着换成新版生成器的输出，跟 A17 原版不是逐字相同（第 5 节）。这些模块我们的产品不编，但 Soong 解析期要求名字闭合，所以 `check-output.py --tree` 会在整棵树里核对。

生成器钉在 `1217e6125d76`（分支头，2026-10-08）。没有用 A17 生成时的那个版本，因为它的配置格式不同（`toolchain.toml`，`meson2hermetic-2` 分支 2026-02 的 `mesonbuild/convert/reference/android/`），实测也不能逐字复现 A17 的输出（22 个文件不同）；而新版本身就是上游用来生成 `vulkan.freedreno` 的那一版（`0c0522d` "Propagate shared library dependencies from linked static targets" 正好补上 A16 坑 C12 说的"静态库的 shared_libs 不传播"）。

## 3. 管线

| 步 | 做什么 | 文件 |
|---|---|---|
| 1 | 前提：`VERSION` 是 26.1.*；python3 ≥ 3.11（生成器用 `tomllib`）。默认拒绝直接改 `~/crdroid/external/mesa3d` | `scripts/mesa-a17/regen.sh` |
| 2 | 拉生成器到 `~/.cache/gaokun-mesa/mesonbuild-<SHA>`（按 SHA 浅取，分支会强推）。也可以 `--generator` 指定 | 同上 |
| 3 | 核对根 `Android.bp` 末尾的 gfxstream 手写块与我们存的那份逐字一致。生成器会把我们这份原样贴回去，上游改过而我们没跟的话，改动会被悄悄回退 | `device/huawei/gaokun3/mesa/hermetic/android/gfxstream_workaround.txt`（= A17 `Android.bp:518-701`） |
| 4 | 打源码补丁（幂等：能反向撤就算已打）：上游 9 个提交 + `patches/0004`。**不打 `patches/0005`**（已证伪，见 stage6-crdroid.md M3「顺带发现」） | `scripts/mesa-a17/backports/`、`patches/0004-*.patch` |
| 5 | 删掉所有带 "The Magma GPU Project" 文件头的旧生成文件，再 `meson convert --config … --platforms … --dependencies … --project-dir <mesa>` | 配置在 `device/huawei/gaokun3/mesa/hermetic/android/` |
| 6 | 后处理只剩一处：`vulkan.freedreno` 补 `compile_multilib: "64"` | `scripts/mesa-a17/postprocess.py` |
| 7 | `bpfmt -l` 做语法检查（prebuilts 里的，只解析不改文件）；`check-output.py` 做自检 | `scripts/mesa-a17/check-output.py` |
| 可选 | `--export` 把全部 Android.bp + 补丁动过的源文件打包，备份进 R2（取代 A16 那份只存在构建机上的 `~/keep/mesa3d-patched.tar.zst`） | — |

### 3.1 配置（`device/huawei/gaokun3/mesa/hermetic/android/`）

* `aosp_mesa3d.toml`：取自上游 main。去掉 `aosp_reference_embedded_drivers`，换成 **`gaokun_turnip`**：只有 `android_arm64`，`vulkan-drivers = "freedreno"`，`freedreno-kmds = "msm"`，EGL / GBM / GL 全关（与 A16 的 `gaokun.toml` 相同，GLES 由 ANGLE 提供）。其余三个配置（gfxstream + lavapipe 参考驱动、模拟器 gfxstream、host lavapipe）保留，只给参考驱动那个加了一行 `platform-sdk-version = 37`（见下）。
  * `zlib` 开、`zstd` 关，与 reference 配置保持一致。公共模块的编译参数是按平台取并集的，两边不一致就会互相污染。
  * `platform-sdk-version = 37`，**`gaokun_turnip` 和 `aosp_reference_drivers` 两边都设**（默认是 35，`meson.options:594-600`；A16 的 `gaokun.toml:97` 是 36）。它除了管 `meson.build:1001-1019` 的 `>=26` / `>=35`（libui → IMapper5）依赖分支，还通过 `-DANDROID_API_LEVEL` 决定 `ANDROID_STRICT` 下放行哪些扩展：`src/vulkan/util/vk_extensions.py:52-61` 生成 `ANDROID_API_LEVEL >= N` 条件，`:385-389` 把 `VK_KHR_compute_shader_derivatives` / `VK_KHR_maintenance7` / `VK_KHR_pipeline_binary` / `VK_KHR_shader_relaxed_extended_instruction` 定在 36。turnip 支持其中三个（`tu_device.cc:177/215/245`），A16 用 36 时它们是暴露的；留默认 35 就会被藏掉，属于相对 A16 的回退（10-25 评审发现，初稿写的"35/36/37 结果一样"不对）。只在 `gaokun_turnip` 里设的话，根 `Android.bp` 会同时出现 `"android"` 分支的 `-DANDROID_API_LEVEL=35` 和 `("arm64","android")` 分支的 `=37`，宏重定义（评审在构建机副本 `~/a17-mesa-review` 上实测）。两边都设之后只剩一个 `=37`，和原输出相比只差这两行，`check-output --tree` 照样全过，重跑 0 变化。reference 配置的 x86 / x86_64 模块我们不编；26.1 里 `>=37` 的门槛只有 intel anv（`anv_instance.c:50`）。数值取 37 是按迁移方案 2.5；对扩展放行来说 36 和 37 效果相同。
  * `android-strict` 不设，等于默认 true，与 A16 一致：A16 归档的 Android.bp 里有 54 处 `-DANDROID_STRICT`。按并集规则，arm64 上的所有模块都会带 `-DANDROID_STRICT`（实测在根 `Android.bp` 的 `("arm64","android")` 分支）。
* `dependencies.toml`：取自上游 main（含 MR !44278 的 `ui → libui`），**只删了 `libzstd`**。生成器的 `func_dependency()`（`mesonbuild/hermetic/hermetic_interpreter.py:137-205`，`:168` 直接 `is_found = True`）只要依赖名在表里就判定"找到"，不看 `required: get_option('zstd')`。实测留着它，turnip 就会链上 `libzstd`，根 `aosp_mesa3d_c_project_args` 也会带上 `-DHAVE_ZSTD`。而 vendor 的 libzstd 没有标 `same_process_hal_file`，enforcing 下 app 进程会加载失败。上游自己生成的 turnip 也链了 libzstd（`gurchetansingh/mesa@vk-freedreno-meson2hermetic-output` 的 `src/freedreno/vulkan/Android.bp:402`）。
* `platforms.toml`：上游原样（NDK r29 / clang 21 的编译器探测表；生成器不调用编译器）。

### 3.2 上游 backport（`scripts/mesa-a17/backports/`）

| # | 上游提交 | 来自 | 为什么要 |
|---|---|---|---|
| 01–04 | `dd47c7c` `b0e480d` `f9a5524` `1084ddd` | MR !41518 | Soong 的全局警告比 NDK 严（ignored-qualifiers、missing-prototypes、implicit-fallthrough、gnu-alignof-expression），对应 A16 坑 C11。04 只改 kgsl 后端，我们不编，但它属于同一组提交，一起打上 |
| 05 | `1fe5838`（**手工 rebase**） | MR !41518 | 寄存器 xml 的 genrule 没声明 `depend_files`，在 Soong 沙箱里找不到 `adreno_common.xml`。原补丁对着 2026-05 的 main，A17 没有 `a8xx_perfcntrs.xml` 和 `perfcntr_files` 段，按原语义重做了 |
| 06 | `00261e5` | MR !41518 | 同上，第 2 部分 |
| 07 | `cb614dd` | MR !44278 | vulkan runtime 的接口依赖要往下游传。不传的话，对应 A16 坑 C8 的"生成头不传播" |
| 08–09 | `12a0367` `b6b0902` | MR !44278 | 让 meson2hermetic 能编 u_gralloc 的 IMapper5 后端（依赖 libui）。A16 的 turnip 就是靠 IMapper5 导入 gralloc buffer 的（`turnip-shared.bp.in` 的注释） |

!44278 的第 4 个提交（`aa75501`）只改上游的 `dependencies.toml`，那一项已经在我们的配置里了。

### 3.3 `patches/0004`（turnip ANB 延迟绑定 v3，重做到 26.1）

* 逻辑和 A16 归档树（26.0.3 + v3）**逐行相同**。归档里的 `tu_image.cc` / `tu_cmd_buffer.cc` 与上游 26.0.3 原文对比，得到 v2 + v3 的完整改动；26.1 的 `tu_image_bind()` 结构没变，锚点只是行号变了（`tu_image.cc:1011`、`tu_cmd_buffer.cc:3681-3684`）。
* 去掉了 D10 的 B1 诊断探针（P1 / P2 / P3、`gaokun_dump_image()` / `gaokun_dump_callers()`），只保留实现本身和"无可绑定"分支的限流 `mesa_logw`。注释改成英文，方便提上游。
* 补丁文件原来存的是 v1 的 diff，权威版本只在 `scripts/gmu-forensics/apply-0004v{2,3}.py` 里。这笔历史欠账一起还了：现在 `patches/0004` 就是可以直接 `git apply` 的 v3。

## 4. 10-25 实跑结果（构建机副本 `~/a17-mesa-work/mesa3d`，`~/crdroid` 未动）

| 项 | 结果 |
|---|---|
| 补丁 | 9 个 backport + 0004 全部 `git apply` 成功；Mac 上对 `refs/a17` 的副本 `git apply --check` 也通过 |
| 生成 | 约 18 秒，无 ERROR。90 个旧 Android.bp → 106 个（`src/freedreno/**` 新增 17 个；`src/gallium/drivers/zink/Android.bp` 消失，它只定义了 `inc_src_gallium_drivers_zink`，经核实没人引用） |
| `vulkan.freedreno` | `src/freedreno/vulkan/Android.bp`：`cc_library_shared`，`vendor: true`，`relative_install_path: "hw"`，`compile_multilib: "64"`（后处理补的）。srcs 里有 `tu_knl_drm_msm.cc`，没有 kgsl / virtio 后端。shared_libs（含静态依赖闭包）= libcutils、libdrm、libhardware、liblog、libnativewindow、libsync、libui、libz，和 A16 一样，少了 IMapper4 那四个 HIDL 库 |
| 与上游参考输出比 | 和 `gurchetansingh/mesa@vk-freedreno-meson2hermetic-output` 的 turnip Android.bp 结构几乎一样。差异只有：我们不编 kgsl、少 `libzstd`、多 `libui`、多 `compile_multilib`，以及 26.1 快照与 2026-05 main 的源文件差别 |
| 模块名闭合 | 490 个模块，引用 35 个外部模块，全部在 `~/crdroid` 里有定义（bison / flex / m4 → `prebuilts/build-tools/Android.bp:78/101/121`；`glslangValidator` → `external/deqp-deps/glslang/Android.bp:264`，`visibility: public`；mako → `external/python/mako/Android.bp:33`；pyyaml → `external/python/pyyaml/lib/yaml/Android.bp:19`） |
| 消失的模块 | 445 个，几乎都是旧版生成器按单个源文件拆出来的 filegroup（`*_c_impl` / `*_h_headers`）。在 external/mesa3d 以外，没有任何 Android.bp 引用它们 |
| 语法 | prebuilts 的 `bpfmt -l` 对全部 106 个文件都不报错（另用坏文件确认过它会报解析错误） |
| 幂等 | 在生成结果上再跑一遍：0 个文件变化 |
| 改动量 | 相对 A17 原版：125 个文件，+6380 / −4011（含补丁改的源文件）；`--export` 打包 257 KB（`~/a17-mesa-work/turnip-a17-bp.tar.gz`）。⚠️ 这份包是 platform-sdk-version 修正**之前**的产物（根 `Android.bp` 里还是 `-DANDROID_API_LEVEL=35`），备份进 R2 前要重新导出 |
| zstd | 最终输出里没有 `libzstd`，也没有 `-DHAVE_ZSTD`；`-DHAVE_ZLIB` 保留 |
| 0004 编译 | NDK r27c clang、`android-stub` 的 meson 交叉构建（scratch，`~/a17-mesa-work/ndk-build`），单独编 `tu_image.cc.o` / `tu_cmd_buffer.cc.o`：无错误、无警告。目标文件引用了 `vk_android_get_anb_layout` / `vk_android_import_anb`，"NULL-memory bind …" 字符串也在，说明 Android 分支确实编进去了 |

### A16 那 12 个坑在 A17 上的状态

| A16 坑（stage5-freedreno.md） | A17 |
|---|---|
| A1–A11 旧生成器的 API 缺口 | 不存在了：新生成器跑的是真正的 meson 解释器 |
| B 解析器啃不动 Windows / Haiku 的 meson 文件 | 不存在了（同上） |
| C1 文件名 `Android_res.bp` | 不存在了：按目录直接写 `Android.bp` |
| C2 与树内手维护模块重名 | 不存在了：树里已经没有手写 bp，只剩根部的 gfxstream 兼容块，靠 `gfxstream_workaround.txt` 原样保留 |
| C3 gfxstream guest 源码搬走 | 不存在了 |
| C4 out / tools / srcs 重复 | bpfmt 通过；Soong 层面要 `m` 才能确认 |
| C5 genrule 少声明 m4 / bison | 已处理：`src/freedreno/ir3/Android.bp` 的 `ir3_parser.ch_*` 写了 `tools: ["bison", "m4"]`，cmd 里有 `M4=$(location m4)` |
| C6 glslangValidator 被裸调用 | 已处理：genrule 用 `tools` + `$(location glslangValidator)`；A17 上游自带 host 模块，`patches/0003` 废弃（tree-fixes 的 [9] 已经撤掉） |
| C7 spv 头的 include 路径 | 已处理：`bvh/Android.bp` 的 genrule 导出了 `src/freedreno/vulkan/bvh` 及各级父目录 |
| C8 generated_headers 不传播 | 生成器直接把 51 个生成头列在 `vulkan.freedreno` 上，backport 07 也补了接口依赖；要 `m` 才能确认 |
| C9 python 脚本缺 mako / pyyaml | 已处理：`python_binary_host` 都写了 `libs: ["mako", "pyyaml"]` |
| C10 漏 libdrm / graphics.common / libui | libdrm、libui 都在。不编 IMapper4 后端，所以 graphics.common 不需要 |
| C11 `-Werror` 比 mesa 严 | backport 01–04 是上游为这件事修的。还有没有剩下的，要 `m` 才知道 |
| C12 要手写共享库包装 | 不需要了：生成器直接出 `vulkan.freedreno`（`target_renames`），只补 `compile_multilib` |
| M3 坑 2 绝对路径烤进 cmd | 不存在了：`-I` 写的是 `external/mesa3d/…`（`project_path`），相对树根。`check-output.py` 会查 |
| D2-2 gralloc 元数据后端是硬需求 | IMapper5 后端在：`_mesa_u_gralloc` 的 srcs 里有 `u_gralloc_imapper5_api.cpp`（backport 09） |

## 5. 对非 turnip 模块的影响（我们的产品不编，但改了就要知道）

* gfxstream / lavapipe 模块从 zstd 换成 zlib。上游 main 也做了同样的改动，配置注释里写了原因。
* arm64 上所有模块都带 `-DANDROID_STRICT`（原来 reference 配置是 `android-strict = false`），这是并集规则的结果。
* reference 配置的 `-DANDROID_API_LEVEL` 从 35 变成 37（第 3.1 节，两边必须同值）。
* 新版生成器的输出风格不同：filegroup 合并了，部分 `select` 被合并。gfxstream 的手写兼容块逐字不变（第 3 步校验）。

## 6. 只有构建能验证的

1. **`m vulkan.freedreno`**（D16 以上）：Soong 解析（重复项、可见性、`select` 语义）、genrule 沙箱（xml / glslang / mako 脚本）、平台 clang 的 `-Werror`、链接（`whole_static_libs` 能不能保住 `HAL_MODULE_INFO_SYM`）。产物验证照旧：`llvm-readelf --dyn-syms vulkan.freedreno.so` 里应该有 `HMI` 和 `vk_icdGetInstanceProcAddr`。
2. **整树 `m`**：确认 goldfish / gfxstream 那些按名引用 mesa 的模块在解析期都没问题（`check-output --tree` 只查了 Android.bp 里带引号的名字，没查 Android.mk）。
3. **安装位置**：`/vendor/lib64/hw/vulkan.freedreno.so` 存在，`/vendor/lib/hw/` 下没有。标签由现有的 `sepolicy/file_contexts` 那条规则处理。
4. **上机**（`scripts/verify-turnip.sh`）：`Turnip Adreno (TM) 690`、SMMU fault 0、screencap 正常。重点看 0004 在 26.1 上的效果，以及 A17 的新 ANGLE 是否还走延迟绑定（P1 那种 NULL-memory bind）。如果"无可绑定"的 `mesa_logw` 出现了，说明有新路径。
5. 游戏回归：`docs/gaming.md`。`ANDROID_STRICT` 下暴露的扩展集应该和 A16 相同。

## 7. 待定 / 没做的

* **32 位 turnip**：生成器的平台表里没有 `android_arm`（`platforms.toml` 只有 arm64 / x86 / x86_64 / 两种 linux），所以 32 位进程没有 Vulkan，32 位 app 的 ANGLE GLES 也跑不起来。这和 A16 一样（A16 也是 `compile_multilib: "64"`）。要支持就得自己用 `meson check-platforms` 造一个 `android_arm` 平台，再把它加进 `gaokun_turnip`。是否需要取决于 32 位老游戏（a17-migration-plan.md 2.3「32 位」）。
* **生成器备份**：它在 GitHub 的个人分支上，会被强推。建议把 `~/.cache/gaokun-mesa/mesonbuild-1217e61…` 打包传 R2；`--export` 的产物也一起传。
* **接入构建流程**：`regen.sh --allow-crdroid-tree` 现在要手动跑。要不要并进 `crdroid-tree-fixes.py`（另一条线的文件）还没定。注意 `repo sync` 会碰这棵脏树（A16 铺归档时也一样）。
* **A16 遗留文件**：`scripts/mesa-tool-fixes.py`、`scripts/mesa-bp-merge.py`、`scripts/join_meson_continuations.py`、`patches/0006`、`device/huawei/gaokun3/mesa/{gaokun.toml,turnip-shared.bp.in}` 已加上"仅 A16"的说明，三个脚本在 A17 树上会直接退出。要不要挪进 `scripts/archive/` 或删掉，由用户定（`NOTICE:30` 引用了 `gaokun.toml`）。
* `patches/0005` 保持不打，文件头已注明"已证伪"。
