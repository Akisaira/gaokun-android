# 指纹驱动设计（gaokun3 / FocalTech FTE7001）

> 状态 2026-09-24：**TA 加载已在硬件验证**（#125，app_id=5/6），命令收发工具就绪（#125 续）。
> 卡在命令帧格式（静态逆向中）。本文是架构与决策的主干，随进展更新。
> 背景/证据：`docs/stage4-findings.md` #120（能不能）→#123（翻案）→#124（移植）→#125（上机成功）；
> 逆向报告在 `docs/fingerprint/`（不入库）。

## 0. 一句话架构

传感器的取图/比对/模板都在 **TrustZone 里的高通签名 TA `fingerprint`**（`fingerpr.mbn`，单一 secelf）。
普通世界（Linux）**不碰传感器 SPI**，只做三件事：① 用 QSEECOM SMC 把这个签名 TA 加载进 QSEE、
② 给 TA 发命令（`FF_CMD_TA_*`）、③ 应答 TA 回调普通世界读写它加密模板的 listener 请求。
Android 侧再包一层 `IFingerprint` HAL。**全程不改 TA、不绕安全启动，TZ 逐段验签。**

```
Android FingerprintService
        │  AIDL IFingerprint/ISession
   [指纹 HAL(用户态)]  ── STRONG，ISharedSecret 签 HAT（本机全软件 KeyMint，#120 §3 已论证可行）
        │  ioctl/字符设备
   [in-kernel client driver]  ── LOAD→app_id、按状态机发 FF_CMD_TA_*、listener 服务(安全存储)
        │  qcom_scm_qseecom_app_load / _app_send / listener  ← patch 0050
   [QSEECOM / TZ]  ── 验签、映射 TA、TA 经 QSEE-SPI 直连传感器
        │
   FocalTech FT9769 模组（FT9391 AFE），中断 GPIO181 / 复位 GPIO185
```

## 1. 已定的决策（有实测支撑）

| # | 决策 | 依据 |
|---|---|---|
| D1 | 走**旧 QSEECOM**（不是 QTEE/SMCInvoke） | gaokun3 在 `qcom_scm_qseecom_allowlist`，本机 `qcom_qseecom`+`uefisecapp` 已 probe（#123 §1） |
| D2 | LOAD 用 samcday/Dawid 的移植（patch 0050），非自研 | 有 SDM670 真机验证；SMC 参数逐字段对上 Windows 逆向（#124） |
| D3 | 单一 secelf ⇒ `mdt_len=0`，整文件传，跳过 mdt 拼接 | fingerpr.mbn 是单 secelf；Windows QcTrEE 的 LOAD 也是 mdt_len=0（#124） |
| D4 | **必须把 scm 设备约束到 32 位 DMA** | 本机 dma-ranges 40 位+内存>4GB；LOAD 物理地址是 SMC32 裸参数会截断（#124/#125 实测镜像落 `0xec000000`） |
| D5 | staging 池分配**正好 4MiB**（不是 img+4MiB） | img<4MiB；img+4MiB=7.7MB 超 MAX_PAGE_ORDER(4MB) `-ENOMEM`（#125）。⚠️ img 若>4MiB 得改走 CMA |
| D6 | 驱动**常驻**加载 TA（不是每次用完卸） | 收发命令要 app_id 稳定；`qcom_qseecom_fpcmd` 已按此验证 |
| D7 | listener 无人认领时安全网兜底 | patch 0050 的 service_listeners 自动 FAILURE、256 轮 -ELOOP，发错命令不硬挂（#125 续） |

## 2. 命令协议（⬜ 逆向中，`fp-cmd-protocol.md`）

已知：命令名 `FF_CMD_TA_*`(37) / `FF_CMD_SVC_*`(34) / `CMD_TO_DEVICE_*`(13)；Windows 客户端观察到用
`0x80xx` 号 + `{cmd(4B), req_len(4B), rsp_len(4B), payload}` 结构（报告 §7）。TA 发送封装函数
`ff_trustlet_client_exchange_message`（别名 `TA_Commication`/`ff_trustlet_RWQSEE`）。
⚠️ 2026-09-24 一次静态复核校正了"安全首发命令"的候选：Windows 的 `ff_sc_GetSCFirmwareVersion` /
`ff_sc_check_health` 里的 **`sc` = sensor controller（传感器 MCU），走 SPI** —— 它们**不是** SPI-free，
不能当第一条只读命令（要先 `INIT_SPI`）。⇒ 真正安全的第一条只能是 **`INIT_SPI` 之前的 TA 级命令**
（`FF_CMD_TA_CREATE` / `FF_CMD_TA_INIT`，纯 TA、不碰传感器；是否碰安全存储待确认）。
⬜ 仍待定死（focused RE，非一次能拆完）：
- 请求 header 的确切布局（含 InvokeCommand 的 magic `0x1255` 与 `{cmd,req_len,rsp_len}` 两说要对齐）、
  以及 `0x80xx` 与 `FF_CMD_TA_*` 枚举序的映射（0x8020≠ordinal 0x20，两套编号，需 TA 分发表）；
- `CREATE`/`INIT` 的确切 cmd 号与字节 —— 定死它 = 能上机跑 M2；
- enroll/authenticate 触发的 **listener 请求/响应缓冲格式**（驱动 `->service()` 要解析）。
> 注：命令协议逆向是【多次会话量级】的独立子任务（TA 是优化过的 aarch64 secelf，分发表运行时注入），
> 不宜边猜边发。M2 需要先把 CREATE/INIT 的确切字节定死，再上机（TA 仍常驻，不用重启）。

## 3. 驱动状态机（草案，待命令号落定）

```
init：      LOAD → app_id → 注册 listener(安全存储) → FF_CMD_TA_INIT → INIT_SPI → PROBE_CHIP_ID → INIT_DEVICE
idle：      等 GPIO181 finger-down 中断（或 QUERY_FINGER_STATUS 轮询）
authenticate：START_SCANNING → CAPTURE_IMAGE → AUTNENTICATE →(listener 读模板)→ 结果 → HAT
enroll：    PRE_ENROLL → 多帧 CAPTURE_IMAGE + ENROLL →(listener 写模板)→ POST_ENROLL
teardown：  FREE_SPI → FREE → 注销 listener → app_shutdown
```
⚠️ enroll/authenticate 会触发 listener 回调 —— **第一次跑这些命令仍需人在设备旁**（安全网只保证不硬挂，
不保证一次成功；模板的安全存储后端要落地，见 §4）。

## 4. 安全存储后端（listener 的 `->service()`）

TA 会请求普通世界替它读写加密模板（它自己用 `qsee_sfs_*` 封装、带防回滚+HMAC）。普通世界只是搬运
密文，看不到明文。落地选项：① 存到 `/data/vendor/` 下的文件（简单，够用）；② RPMB（防回滚，Windows 用的）。
先做 ①。格式由逆向出的 listener 消息结构决定。

## 5. GPIO 与设备树

Windows ACPI `\_SB.SPBA`：中断 **GPIO181**（edge/active-high/wake）、**GPIO185**（复位，推测）。
本机 DT 里这两脚都空闲、不在 `gpio-reserved-ranges`（#120）。驱动需要 GPIO181 做 finger-down 中断；
GPIO185 复位可能由 TA 经 QSEE-GPIO 自己做（待确认）。届时加一个 fingerprint 的 DT 节点带这两脚。
⚠️ 传感器的 SPI **归 TZ**，DT 里【不要】给它建 spi 节点。

## 6. Android HAL

以 AOSP 虚拟 HAL（`hardware/interfaces/biometrics/fingerprint/aidl/default/`）为骨架，
把 `FakeFingerprintEngine` 的 enroll/authenticate 换成"经字符设备驱动真实取图+TA 比对"，
`SensorProps` 设 `STRONG`，接 `ISharedSecret` 用同一把软件 HMAC 密钥签 HAT —— 本机 KeyMint/gatekeeper
都是软件实现，三方协商同一密钥，keystore 会认（#120 §3）。强度设 STRONG 才能绑 keystore 与 72h 免密。

## 7. 里程碑

- [x] M1 LOAD 成功（#125）
- [ ] M2 SEND 一条只读命令成功（证明能与 TA 对话）← **当前目标**
- [ ] M3 init 序列跑通（INIT/INIT_SPI/PROBE_CHIP_ID 拿到芯片 ID）
- [ ] M4 listener 服务 + 一次 authenticate（含安全存储读）
- [ ] M5 enroll 落一枚模板
- [ ] M6 client driver 成形（字符设备接口）
- [ ] M7 Android 指纹 HAL，Settings 里能录/解锁
