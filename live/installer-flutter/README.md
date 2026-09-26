# gaokun3 图形安装器（Flutter）

LiveCD 上的图形安装流程。取代 C 版 `live/installer/`（C + cairo 直画 DRM，20 屏；M0 验收过后 2026-09-26 删掉，
最后一版 `git show 445e978:live/installer/…`）——
决定与理由见 [`docs/stage7-flutter-debian.md`](../../docs/stage7-flutter-debian.md)。

## 分区逻辑不在这里

界面**不实现任何分区逻辑**：每一个"能不能 / 够不够 / 多大"都问
[`scripts/live/installer-lib.sh`](../../scripts/live/installer-lib.sh)，命令行安装器
`scripts/install-gaokun3.sh` 用的是同一份实现。连"双系统至少要多少空间"都是用一个
空区间去问 `gk3_plan`，由它在 `PLANERR need_mib=` 里报出来（C 版在文案里写死了
"不足 20.2 GiB"，而带救援系统时实际是 21.2 GiB）。

```
lib/backend/   protocol.dart（行协议 + 百分号解码）· shell_backend.dart（真后端）· fixture_backend.dart（回放）
lib/model/     把行记录解读成类型 —— 只解读，不计算
lib/session.dart  一次安装的全部状态：用户的选择 + 从后端问来的事实
lib/ui/        每一屏；布局在固定的 1280×800 逻辑画布上（app.dart 的 LogicalCanvas）
testdata/      fixture：真后端在容器里录的输出（见下）
```

⚠️★ 调后端时参数**不拼进 shell 字符串**：`bash -c '. "$0" && "$@"' <lib> <函数> <参数…>`
（`shell_backend.dart`）。否则一个含单引号或 `$(…)` 的 WiFi 密码就是一次以 root 执行的命令注入。

## 在 Mac 上开发（不需要设备，也不需要 Xcode）

```sh
python3 tool/fetch-fonts.py               # 第一次：取打包进应用的 Roboto 与 Noto Sans CJK SC（连着设备，或 --from <目录>）
flutter test                              # 全部：协议 · 流程 · 文案约定 · 出图
flutter test test/shots_test.dart         # 出图 → test/shots/*.png（C 版 make shots 的等价物）
flutter run -d chrome --web-browser-flag=--window-size=1280,800   # 交互预览，默认场景 windows-free
#   换场景：地址栏加 ?scenario=factory | windows-free | blank | android
```

★ 出图不是可有可无的：这一轮的**占位符参数填反**（"可用空间不足 0 MiB（最大的一块是 21.2 GiB）"、
"创建 /dev/nvme0n1p1 的分区…EFI 分区 80 GiB"）测试全绿，是看图才发现的 —— 测试和代码用了同样错的顺序。
改界面之后**看一遍图**。

### 界面：Material Design 3（用户 2026-09-25）

* 颜色只用 MD3 的角色：`ColorScheme.fromSeed`（种子沿用 C 版的强调蓝）；MD3 没有的"成功 / 警告"是
  `Gk3Colors`（`lib/ui/theme.dart`），按 MD3 自定义颜色的做法先向主色调和、再生成四件套。**不写死颜色。**
* 大屏布局：左侧不可点的步骤栏（MD3 导航抽屉的样子，当前项是 secondary-container 胶囊）+ 右侧内容；
  底栏"返回"是 text button、"下一步"是 filled button；可选卡片未选是描边卡、选中是 secondary-container + 单选指示；
  危险操作用 error 角色（整盘清空、按住 2 秒）。
* 字体打包进应用（pubspec 的 `fonts`）：拉丁 Roboto、中文 Noto Sans CJK SC，都是可变字重 ——
  ⚠️ Flutter 不会把 `fontWeight` 映射到 wght 轴，`buildTheme()` 给每个样式补了 `FontVariation`，
  漏了的话标题和正文一样粗。
* 尺寸：MD3 的 type scale 原样用；按钮 56、列表项 ≥ 72（MD3 的下限 48 dp，本机 ≈ 37 逻辑像素，见 `kTouch` 的注释）。

### fixture 从哪来

**真后端在容器里录的**，不是手写的（手写 = 界面对着一份想象中的协议开发）：

```sh
bash scripts/live/test-in-container.sh scripts/live/gen-fixtures.sh
```

| 场景 | 是什么 |
|---|---|
| `factory` | 出厂布局（`docs/hw-inventory.md` 第 8 节）：整盘都是 Windows、没有空闲区 → 走"缩分区" |
| `windows-free` | 在 factory 上**真跑一次** `gk3_shrink` 之后：80 GiB 空闲 → 走双系统 |
| `blank` | 空盘 → 走整盘 |
| `android` | blank 上真装一遍之后：双系统被 `partlabel-conflict` 拒绝 |
| `common` | 与盘无关的调用。其中**手写**的几条（预检、连 WiFi、变体清单）是容器里做不到的，`index.txt` 里逐条标明 |

索引里的 `@next gk3_shrink windows-free` 让演示走得通"出厂 → 缩分区 → 双系统"：缩成功后
接着按缩完之后录的那份回放。找不到的调用返回失败（127）而不是编一个结果。

## 界面上的几个决定（继承自 C 版的 `README.md`：`git show 445e978:live/installer/README.md`）

* 逻辑坐标固定 1280×800，整体缩放；旋转交给 cage
* 触摸目标：按钮 56、列表项 ≥ 72 逻辑像素（软键盘：键帽 48 + 缝 8）。C 版定的是 88；改 MD3 时按 MD3 的下限
  （48 dp ≈ 本机 37 逻辑像素）收回来，理由写在 `lib/ui/theme.dart` 的 `kTouch`
* 最后一步和缩分区是**按住 2 秒**；键盘上按住回车 / 空格也行 —— 触摸坏了不能变砖
* 做不到的选项**禁用并写明原因**，不藏起来（安装 U 盘也列出来，写明"不能装到它上面"）
* 导航就是 Navigator 的栈：返回 = 回到真正来的那一页（C 版 `screen--` 掉进过没走过的分支屏）
* 焦点框只在用过键盘之后出现（Flutter 的 `FocusManager.highlightMode` 自带）；Esc = 返回
* WiFi 两步式：先选网络，再单独一屏输密码 + 软键盘；信号显示成格数；企业网络（EAP）禁用并写明原因

## 这一轮踩到的坑

* **gen-l10n 的方法参数顺序 = 模板 ARB 里 `@元数据` 的顺序**，不是占位符在文案里出现的顺序。
  元数据按字母序生成时，8 条多占位符文案有 6 条填反。现在按出现顺序生成，`test/l10n_test.dart` 钉住。
* **C 版文案里的 `\n` 是给固定宽度的 cairo 排版准备的**。Flutter 自动折行后再叠一个硬换行，
  就成了"将为你启动\n系统，\n内核"。只保留语义上的分段。
* **测试里别用 `rootBundle` 读 fixture**：它缓存 `loadString` 的 Future，上一个测试结束时还在飞的
  那次读取挂在它的 FakeAsync 区里永远完成不了，下一个测试 await 它就永远等下去（单独跑全过、
  一起跑 7 条挂 6 条）。测试用 `test/helpers.dart` 的 `DiskBundle` 同步读盘。
* 测试里默认没有 Material 图标字体（全是空心方块）：出图时从 `$FLUTTER_ROOT` 加载。真机上
  `uses-material-design` 会把它打包进去。
* 模板的 Linux runner 在 Wayland 下会画一条 GtkHeaderBar 标题栏 —— 在 cage 里就是屏幕顶上一条
  带关闭按钮的栏，安装到一半被点掉就完了。`linux/runner/my_application.cc` 改成无边框全屏
  （`GK3_WINDOWED=1` 退回窗口，给 Linux 开发机用）。

## 版本

Flutter **3.47.2** stable / Dart 3.13.2（`pubspec.yaml` 的 `environment.flutter`；`pubspec.lock` 入库）。
⚠️ 这个版本上 Linux 默认走 Impeller，而 flutter/flutter#192915 报的正是"Impeller 成为 Linux 默认后
在弱 GPU / 软件驱动上闪烁"—— 真机 M0 要把 `--no-enable-impeller`（Skia）也测一遍。

## Linux arm64 版

```sh
bash scripts/live/build-flutter.sh                 # Mac 上的 arm64 容器里原生构建 → out/installer-flutter-linux-arm64/（22 MiB）
bash scripts/live/test-render.sh 60                # headless cage 里真跑：截图 + RSS → out/render-test/
SOAK=1 RENDERER=skia bash scripts/live/test-render.sh 600   # 浸泡：持续出帧，量帧率与 RSS
```

运行时开关（都是环境变量）：`GK3_FIXTURE=<场景>` 演示数据 · `GK3_SOAK=1` 浸泡页 ·
`GK3_RENDERER=skia` 关 Impeller · `GK3_WINDOWED=1` 窗口模式 · `GK3_LIB=<路径>` 指定后端。

⚠️ **中文字体**：Flutter 在 Linux 上**不按字符回退**系统字体（装了文泉驿、fontconfig 也查得到，中文照样是方块），
主题里按名字列了回退字体。这一点离线出图验不出来 —— 改了字体相关的东西，看 `test-render.sh` 的截图。
⚠️ release 版不读 `FLUTTER_ENGINE_SWITCHES`（引擎源码 `engine_switches.cc:16-18`），所以切后端用我们自己的 `GK3_RENDERER`。
⚠️ cage 要带 `-s`，否则不能切 VT（命令行逃生口失效）。

## 还没做

* Debian 根文件系统（mmdebstrap）与会话服务（cage -s + wlr-randr 设旋转/缩放）
* 真机 M0：mesa/freedreno 能不能出画面、10 分钟浸泡的 RSS 曲线（两种后端）、`chvt 2` 逃生口
