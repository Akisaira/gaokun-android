# 打包进安装器的字体

字体文件本身不入库（`python3 tool/fetch-fonts.py` 取，sha256 钉在脚本里），这份说明入库。

| 文件 | 字体 | 许可证 | 上游 |
|---|---|---|---|
| `NotoSansSC-VF.otf` | Noto Sans CJK SC（可变字重 400–900） | SIL Open Font License 1.1 | https://github.com/notofonts/noto-cjk |
| `Roboto-VF.ttf` | Roboto（可变字重 100–900、宽度 75–100） | Apache License 2.0 / OFL 1.1 | https://github.com/googlefonts/roboto-3-classic |

两份都取自本仓 ROM 里 Android 自带的 `/system/fonts`（Noto CJK 那份是 5 个字形版本的集合，脚本拆出 SC）。
Material Design 3 的字体就是这两套：拉丁 Roboto，中日韩 Noto Sans CJK。
