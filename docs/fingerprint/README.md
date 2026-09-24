# 指纹逆向报告（本目录 *.md 不入版本库）

MateBook E Go（gaokun3）的指纹是 **FocalTech `FTE7001`**（部分机型 Goodix `GDIX5125`，由 GPIO61/62 strap 选型）。
取图 / 注册 / 比对 / 模板存储全在一个 **Qualcomm 签名的可信应用 `fingerpr.mbn`**（TA 名 `fingerprint`）里，
运行于 TrustZone，SPI 由安全世界持有。要在本机 Linux/Android 上用它，路线是**用厂商自己的 QSEECOM SMC
把这个厂商签名的 TA 加载进 QSEE**（TZ 仍逐段验签，不改 TA、不绕安全启动），再写 client driver + Android HAL。
完整分析、去风险结论、分步计划见 **`docs/stage4-findings.md` #120 与 #123**（受版本控制）。

## 本目录的三份报告（gitignore，只在本地 / 会话上传里）

| 文件 | 内容 |
|---|---|
| `gaokun3-fingerprint-tee.md` | TA 加载机制总纲：QSEECOM LOAD 缺口、SMC 参数、tzmem/SHM-bridge、samcday 参考实现、allowlist |
| `QcTrEE-load-reverse-report.md` | 从 Windows `QcTrEE.sys` 逆出的 LOAD 全链路（SMC `0x32000101`、<4GB 物理地址约束、内存分配） |
| `fingerpr-command-report.md` | `fingerpr.mbn` 的命令分发 + `FF_CMD_TA_*`(37) / `FF_CMD_SVC_*`(34) / `CMD_TO_DEVICE_*`(13) 清单 |

## 为什么不入库
`fingerpr.mbn` / `QcTrEE.sys` / `FtWbioDriverUmdf.dll` 是华为/高通签名的专有二进制；这些是对它们的静态逆向笔记。
与 `firmware/` 同样处理：整类忽略、只留 README。二进制本身从公开的
`matebook-e-go/uup-drivers-sc8280xp` release 取（同 `device/huawei/gaokun3/firmware/README.md`）。
