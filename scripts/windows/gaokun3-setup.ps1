<#
.SYNOPSIS
  gaokun3（华为 MateBook E Go）免 U 盘安装：在 Windows 里把 Android 安装器放上内置盘，下次开机进安装器。
  gaokun3 USB-free install: put the Android installer on the internal disk from Windows; the next boot starts it.

.DESCRIPTION
  以管理员身份运行（双击同目录的 gaokun3-setup.cmd）。每一步之前先检查、先说清楚，真动盘之前要你输入 YES：
    1. 预检：型号 GK-W7X、Windows on ARM、UEFI、安全启动已关；BitLocker 开着时先要你确认拿得到恢复密钥
    2. 让 Windows 自己"压缩卷"（默认 D:），缩出 Android 要的空间 + 一个放安装器的小分区
       —— 由 Windows 来缩，是因为它能处理 BitLocker / 设备加密、不可移动的文件；Linux 的 ntfsresize 对加密卷无能为力
    3. 在缩出来的空间【开头】建 FAT32 分区 GK3LIVE，放 live 系统（和可选的安装载荷、WiFi 配置）
    4. ESP 上放 systemd-boot、内核、dtb、initramfs 和一个启动项（\EFI\gaokun3\、\loader\entries\gaokun3-live.conf）
    5. bcdedit 设"只下一次"从它启动 —— 不改默认启动项；不想装了，重启就回 Windows
  之后安装器里选"保留现有系统"，Android 装进 GK3LIVE 后面那段空闲区。

  -Uninstall 撤掉以上全部（在 Android 装上之前；装上之后只撤启动项与 ESP 上的安装器文件）。

.NOTES
  ⚠️ 这个脚本是在【没有 Windows 的机器上】写的（仓库作者那台的 Windows 已在 2026-08-20 抹掉）。
     纯逻辑（WiFi 配置转换、PSK 推导、大小计算、bcdedit 输出解析）在 PowerShell 容器里有单元测试
     （scripts/windows/test-setup.ps1）；Resize-Partition / New-Partition / mountvol / bcdedit 这些
     Windows 专有的步骤【还没在真机上跑过】。见 docs/stage7-flutter-debian.md §5.8。
  ⚠️ 必须兼容 Windows 自带的 PowerShell 5.1（不用 ?:、??、&& 这些 7 才有的语法），
     文件必须是 UTF-8 带 BOM —— 否则 5.1 按系统代码页读，中文全是乱码。
#>
[CmdletBinding()]
param(
    # 给 Android 的空间（GiB）。安装器的双系统至少要约 21.2 GiB（gk3_plan 实测，含救援分区）
    [ValidateRange(24, 2048)][int]$AndroidGiB = 64,
    # 从哪个卷缩。出厂有独立的 D:（Data，336.6 GiB，docs/hw-inventory.md 第 8 节），缩它比缩 C: 稳
    [ValidatePattern('^[A-Za-z]$')][string]$ShrinkDrive = 'D',
    # 安装器分区（GK3LIVE）的大小：live 185 MiB + 救援 104 MiB + 可选载荷 1.2 GiB
    [ValidateRange(1024, 16384)][int]$LiveMiB = 4096,
    # current：只带当前连着的 WiFi；all：带上所有保存过的；none：不带（到安装器里再连）
    [ValidateSet('current', 'all', 'none')][string]$Wifi = 'current',
    # 不用 bcdedit 的"只下一次"，改为接管 ESP 的回落路径 \EFI\Boot\bootaa64.efi（原件留 .before-gaokun3）
    # —— 这是本机 2026-08-20 在 Windows 还在盘上时实测过的机制（hw-inventory.md 第 8quater 节）；
    #    bcdedit 的 bootsequence 在这台机器的固件上还没验证过。开机会出 systemd-boot 菜单，Windows 在菜单里
    [switch]$UseFallbackPath,
    [switch]$Uninstall,
    [switch]$SkipModelCheck,
    # 不问 YES（给自动化用；人来跑请别加）
    [switch]$Yes,
    [switch]$NoReboot
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'

$script:UseZh = (Get-UICulture).Name -like 'zh*'
$EspType    = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$BasicType  = '{ebd0a0a2-b9e5-4433-87c0-68b6b72699c7}'
$LiveLabel  = 'GK3LIVE'
$EntryTitle = 'gaokun3 installer'
# ESP 要留的空间：Android 150 MiB（installer-lib.sh 的 GK3_ESP_NEED_MIB）+ 这里放的安装器约 20 MiB
$EspNeedMiB = 170
# 压缩之后 Windows 至少还要剩这么多空闲（在"最小能缩到"之上）—— 缩到贴底，Windows 就没地方更新了
$WindowsKeepGiB = 10
# C:\ProgramData\gaokun3（用 .NET 取而不用 $env:ProgramData：后者在 Linux 上是空的，容器里的单元测试一 dot-source 就会炸）
$DataDir    = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'gaokun3'
$StateFile  = Join-Path $DataDir 'windows-setup.json'

# ── 纯逻辑（test-setup.ps1 在容器里测这些）──────────────────────────────────

function T([string]$Zh, [string]$En) { if ($script:UseZh) { return $Zh } return $En }

function Get-BcdGuid([string]$Text) {
    # bcdedit /copy 的回显是本地化的（中文 Windows："已将该项成功复制到 {…}。"），只认 GUID
    $m = [regex]::Match($Text, '\{[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}')
    if ($m.Success) { return $m.Value }
    return $null
}

function Get-ShrinkTarget([long]$CurrentBytes, [long]$MinBytes, [long]$WantBytes, [long]$KeepBytes) {
    # 压缩之后的大小（字节，按 1 MiB 向下对齐）；缩不出这么多返回 $null
    $target = [long]([math]::Floor(($CurrentBytes - $WantBytes) / 1MB)) * 1MB
    if ($target -lt ($MinBytes + $KeepBytes)) { return $null }
    return $target
}

function ConvertTo-HexString([byte[]]$Bytes) {
    return (($Bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

function ConvertFrom-HexString([string]$Hex) {
    $out = New-Object byte[] ($Hex.Length / 2)
    for ($i = 0; $i -lt $out.Length; $i++) { $out[$i] = [Convert]::ToByte($Hex.Substring($i * 2, 2), 16) }
    return ,$out
}

function Get-WpaPsk([string]$Passphrase, [byte[]]$Ssid) {
    # IEEE 802.11i：PSK = PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32)。
    # 自己写而不用 Rfc2898DeriveBytes：它（.NET Framework）要求盐至少 8 字节，而 SSID 常常更短。
    # ★ 写进配置的是这个 64 位十六进制的 PSK，不是明文密码。
    $hmac = [System.Security.Cryptography.HMACSHA1]::new([Text.Encoding]::UTF8.GetBytes($Passphrase))
    $out = New-Object byte[] 40
    for ($block = 1; $block -le 2; $block++) {
        $salt = [byte[]]($Ssid + [byte[]](0, 0, 0, $block))
        $u = $hmac.ComputeHash($salt)
        $t = [byte[]]$u.Clone()
        for ($i = 1; $i -lt 4096; $i++) {
            $u = $hmac.ComputeHash($u)
            for ($j = 0; $j -lt 20; $j++) { $t[$j] = $t[$j] -bxor $u[$j] }
        }
        [Array]::Copy($t, 0, $out, ($block - 1) * 20, 20)
    }
    return (ConvertTo-HexString $out).Substring(0, 64)
}

function ConvertTo-WpaNetwork([xml]$WlanProfile) {
    # netsh wlan export profile key=clear 导出的一份 WLAN 配置 → wpa_supplicant 的一个 network 块。
    # 不支持的（企业网 802.1X、WEP）返回 $null。SSID 一律写成十六进制，免得中文/特殊字符出错。
    # （参数不叫 $Profile：它不分大小写地撞上自动变量 $PROFILE）
    $ns = New-Object System.Xml.XmlNamespaceManager($WlanProfile.NameTable)
    $ns.AddNamespace('w', 'http://www.microsoft.com/networking/WLAN/profile/v1')
    $hexNode = $WlanProfile.SelectSingleNode('//w:SSIDConfig/w:SSID/w:hex', $ns)
    $nameNode = $WlanProfile.SelectSingleNode('//w:SSIDConfig/w:SSID/w:name', $ns)
    if ($hexNode) { $ssid = ConvertFrom-HexString $hexNode.InnerText.Trim() }
    elseif ($nameNode) { $ssid = [Text.Encoding]::UTF8.GetBytes($nameNode.InnerText) }
    else { return $null }
    $ssidHex = ConvertTo-HexString $ssid
    $authNode = $WlanProfile.SelectSingleNode('//w:MSM/w:security/w:authEncryption/w:authentication', $ns)
    $encNode = $WlanProfile.SelectSingleNode('//w:MSM/w:security/w:authEncryption/w:encryption', $ns)
    $oneX = $WlanProfile.SelectSingleNode('//w:MSM/w:security/w:authEncryption/w:useOneX', $ns)
    $keyNode = $WlanProfile.SelectSingleNode('//w:MSM/w:security/w:sharedKey/w:keyMaterial', $ns)
    if (-not $authNode) { return $null }
    if ($oneX -and $oneX.InnerText -eq 'true') { return $null }
    # ⚠️ WEP 的 authentication 也写作 open（或 shared）—— 不先看 encryption，就会当成开放网络写出错的配置
    if ($encNode -and $encNode.InnerText -eq 'WEP') { return $null }
    $key = $null; if ($keyNode) { $key = $keyNode.InnerText }
    $lines = @('network={', "    ssid=$ssidHex")
    switch ($authNode.InnerText) {
        'open' { $lines += '    key_mgmt=NONE' }
        { $_ -eq 'WPA2PSK' -or $_ -eq 'WPAPSK' } {
            if (-not $key) { return $null }
            if ($key -match '^[0-9a-fA-F]{64}$') { $lines += "    psk=$($key.ToLower())" }
            elseif ($key.Length -ge 8 -and $key.Length -le 63) { $lines += "    psk=$(Get-WpaPsk $key $ssid)" }
            else { return $null }
            $lines += '    key_mgmt=WPA-PSK'
        }
        'WPA3SAE' {
            # SAE 用不了预先推导的 PSK，只能写明文；带双引号的密码写不进 wpa_supplicant 的引号串
            if (-not $key -or $key.Contains('"')) { return $null }
            $lines += "    sae_password=`"$key`""
            $lines += '    key_mgmt=SAE'
            $lines += '    ieee80211w=2'
        }
        default { return $null }
    }
    $lines += '}'
    return ($lines -join "`n")
}

function Format-LoaderConf {
    # 只在 ESP 上【还没有】loader.conf 时写（Android 装上之后 gk3_apply 会改写它，原件留 .before-gaokun3）
    return (@('timeout 5', 'default gaokun3-live.conf', 'editor no', 'console-mode keep') -join "`n") + "`n"
}

# ── 与系统打交道 ──────────────────────────────────────────────────────────────

function Say([string]$Zh, [string]$En) { Write-Host (T $Zh $En) }
function Step([string]$Zh, [string]$En) { Write-Host ''; Write-Host ('== ' + (T $Zh $En)) -ForegroundColor Cyan }
function Warn([string]$Zh, [string]$En) { Write-Host ('!  ' + (T $Zh $En)) -ForegroundColor Yellow }
function Fail([string]$Zh, [string]$En) { Write-Host ('!! ' + (T $Zh $En)) -ForegroundColor Red; exit 1 }

function Invoke-Bcd([string[]]$BcdArgs) {
    $out = & bcdedit.exe @BcdArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "bcdedit $($BcdArgs -join ' ') -> $LASTEXITCODE`n$out" }
    return $out
}

function Get-FreeDriveLetter {
    $used = @((Get-PSDrive -PSProvider FileSystem).Name)
    foreach ($c in [char[]]'SRQPONMLKJIHGTUVWXYZ') { if ($used -notcontains [string]$c) { return [string]$c } }
    throw 'no free drive letter'
}

function Mount-Esp {
    $l = Get-FreeDriveLetter
    & mountvol.exe "$($l):" /S | Out-Null
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "$($l):\EFI")) { Fail "挂不上 ESP（mountvol /S 失败）" 'cannot mount the ESP (mountvol /S failed)' }
    return "$($l):"
}
function Dismount-Esp([string]$Esp) { & mountvol.exe $Esp /D | Out-Null }

function Test-AndroidInstalled([string]$Esp) {
    return [bool](Get-ChildItem -Path "$Esp\loader\entries" -Filter '*-android-*.conf' -ErrorAction SilentlyContinue)
}

function Confirm-Yes([string]$Zh, [string]$En) {
    if ($Yes) { return }
    Write-Host ''
    $a = Read-Host (T "$Zh`n输入 YES 继续，其他任何输入都会退出" "$En`nType YES to continue; anything else quits")
    if ($a -cne 'YES') { Say '已退出，什么都没改。' 'Quit. Nothing was changed.'; exit 0 }
}

function Test-Bundle([string]$Dir) {
    $sums = Join-Path $Dir 'SHA256SUMS'
    if (-not (Test-Path $sums)) { Fail "安装包不完整：缺 SHA256SUMS（$Dir）" "incomplete bundle: SHA256SUMS missing ($Dir)" }
    foreach ($line in Get-Content $sums) {
        if ($line -notmatch '^([0-9a-f]{64})\s+\*?(.+)$') { continue }
        $want = $Matches[1]; $rel = $Matches[2]
        $f = Join-Path $Dir ($rel -replace '/', '\')
        if (-not (Test-Path $f)) { Fail "安装包缺文件：$rel" "bundle is missing $rel" }
        $got = (Get-FileHash -Algorithm SHA256 -Path $f).Hash.ToLower()
        if ($got -ne $want) { Fail "安装包里的 $rel 损坏了（sha256 不对）—— 重新下载" "$rel is corrupt (sha256 mismatch) - download again" }
    }
}

function Save-State($State) {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    $State | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function New-LiveVolume([int]$Disk, $Shrunk) {
    Step "3/5 新建 $LiveLabel" "3/5 Creating $LiveLabel"
    # GK3LIVE 放在缩出来那段的【开头】，Android 装在它后面 —— 与 fixture 场景 windows-live 的布局一致
    $off = [long]([math]::Ceiling(($Shrunk.Offset + $Shrunk.Size) / 1MB)) * 1MB
    $np = New-Partition -DiskNumber $Disk -Offset $off -Size ([long]$LiveMiB * 1MB) -GptType $BasicType -AssignDriveLetter
    Format-Volume -Partition $np -FileSystem FAT32 -NewFileSystemLabel $LiveLabel -Confirm:$false -Force | Out-Null
    return (Get-Volume -FileSystemLabel $LiveLabel)
}

# ── 撤销 ─────────────────────────────────────────────────────────────────────

function Invoke-Uninstall {
    Step '撤销免 U 盘安装' 'Undoing the USB-free install'
    $state = $null
    if (Test-Path $StateFile) { $state = Get-Content $StateFile -Raw | ConvertFrom-Json }
    $esp = Mount-Esp
    try {
        $android = Test-AndroidInstalled $esp
        if ($state -and $state.bcd) {
            try { Invoke-Bcd @('/delete', $state.bcd) | Out-Null; Say "删了启动项 $($state.bcd)" "removed boot entry $($state.bcd)" }
            catch { Warn "删启动项失败（可能已经不在了）：$_" "could not remove the boot entry (maybe already gone): $_" }
        }
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue "$esp\EFI\gaokun3", "$esp\loader\entries\gaokun3-live.conf"
        if (-not $android) {
            if ($state -and $state.loaderConfCreated) { Remove-Item -Force -ErrorAction SilentlyContinue "$esp\loader\loader.conf" }
            $bak = "$esp\EFI\Boot\bootaa64.efi.before-gaokun3"
            if ($state -and $state.fallback -and (Test-Path $bak)) {
                Copy-Item -Force $bak "$esp\EFI\Boot\bootaa64.efi"; Remove-Item -Force $bak
                Say '回落路径的 bootaa64.efi 已还原成原件' 'restored the original fallback bootaa64.efi'
            }
        }
        Say 'ESP 上的安装器文件已删' 'installer files removed from the ESP'
    } finally { Dismount-Esp $esp }
    $drive = $ShrinkDrive
    if ($state -and $state.shrinkDrive) { $drive = $state.shrinkDrive }
    if ($android) {
        Warn 'Android 已经装上了：GK3LIVE 分区与压缩出去的空间都留着（Android 在用那段空间）。' 'Android is installed: the GK3LIVE partition and the shrunk space are left alone.'
        return
    }
    $vol = Get-Volume -FileSystemLabel $LiveLabel -ErrorAction SilentlyContinue
    if ($vol) {
        $p = $vol | Get-Partition
        Confirm-Yes "要删掉分区 $LiveLabel（磁盘 $($p.DiskNumber) 分区 $($p.PartitionNumber)），并把 $($drive): 扩回原来的大小。" "About to delete partition $LiveLabel and grow $($drive): back."
        Remove-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
    }
    if ($vol -or ($state -and $state.shrunkBytes -gt 0)) {
        $max = (Get-PartitionSupportedSize -DriveLetter $drive).SizeMax
        Resize-Partition -DriveLetter $drive -Size $max
        Say "$($drive): 已扩回 $([math]::Round($max / 1GB, 1)) GiB" "$($drive): grown back to $([math]::Round($max / 1GB, 1)) GiB"
    }
    Remove-Item -Force -ErrorAction SilentlyContinue $StateFile
    Say '撤销完成。' 'Done.'
}

# ── 主流程 ───────────────────────────────────────────────────────────────────

function Invoke-Setup {
    $here = Split-Path -Parent $PSCommandPath

    Step '1/5 预检' '1/5 Checks'
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) { Fail '要以管理员身份运行（双击 gaokun3-setup.cmd 会自动请求）' 'run as Administrator (gaokun3-setup.cmd asks for it)' }
    if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') { Fail "这不是 ARM64 的 Windows（$env:PROCESSOR_ARCHITECTURE）" "this is not Windows on ARM ($env:PROCESSOR_ARCHITECTURE)" }
    $model = (Get-CimInstance Win32_ComputerSystem).Model
    if ($model -ne 'GK-W7X' -and -not $SkipModelCheck) { Fail "型号是 $model，这个安装器只给 MateBook E Go 2022（GK-W7X）" "model is $model; this installer is for the MateBook E Go 2022 (GK-W7X) only" }
    Say "型号 $model" "model $model"
    try { $sb = Confirm-SecureBootUEFI } catch { Fail '不是 UEFI 启动（或读不到安全启动状态）' 'not booted in UEFI mode (or Secure Boot state unreadable)' }
    if ($sb) { Fail '安全启动开着：内核没有签名，开着就起不来。进固件设置关掉安全启动后再运行' 'Secure Boot is on: the kernel is unsigned. Turn Secure Boot off in firmware setup, then run this again' }
    Say '安全启动已关' 'Secure Boot is off'
    $bl = $null
    try { $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop } catch { }
    if ($bl -and $bl.ProtectionStatus -eq 'On') {
        Warn "$env:SystemDrive 开着 BitLocker（或设备加密）。改了启动方式之后，Windows 下次开机可能要你输入恢复密钥。" "BitLocker (or device encryption) is on for $env:SystemDrive. After the boot path changes, Windows may ask for the recovery key."
        Warn '先确认你拿得到恢复密钥（Microsoft 账户：https://aka.ms/myrecoverykey），再继续。（这一条没在本机上实测过）' 'Make sure you have the recovery key (https://aka.ms/myrecoverykey) before going on. (Not verified on this machine.)'
        Confirm-Yes '我已经拿到了恢复密钥。' 'I have the recovery key.'
    }
    Test-Bundle $here
    Say '安装包校验通过（sha256）' 'bundle verified (sha256)'

    $sys = Get-Partition -DriveLetter $env:SystemDrive.Substring(0, 1)
    $disk = $sys.DiskNumber
    $shr = Get-Partition -DriveLetter $ShrinkDrive -ErrorAction SilentlyContinue
    if (-not $shr) { Fail "没有 $($ShrinkDrive): 盘（用 -ShrinkDrive 指定要压缩的卷，比如 C）" "there is no $($ShrinkDrive): (pick the volume to shrink with -ShrinkDrive, e.g. C)" }
    if ($shr.DiskNumber -ne $disk) { Fail "$($ShrinkDrive): 不在系统盘上" "$($ShrinkDrive): is not on the system disk" }
    if ((Get-Disk -Number $disk).PartitionStyle -ne 'GPT') { Fail '系统盘不是 GPT' 'the system disk is not GPT' }

    # ⚠️ 不在 try 里 exit：finally 不保证跑，ESP 会一直挂在那个盘符上 —— 先卸载、再判
    $esp = Mount-Esp
    try {
        $free = [System.IO.DriveInfo]::new("$esp\").AvailableFreeSpace
        $hasAndroid = Test-AndroidInstalled $esp
        $hasOurs = Test-Path "$esp\EFI\gaokun3"
    } finally { Dismount-Esp $esp }
    $freeMiB = [math]::Floor($free / 1MB)
    # 重跑时我们自己的文件已经占了一份，按"还要多少"算
    if ($freeMiB -lt $EspNeedMiB -and -not $hasOurs) {
        Fail "ESP 只剩 $freeMiB MiB，要 $EspNeedMiB MiB（Android 150 + 安装器 20）" "the ESP has only $freeMiB MiB free; $EspNeedMiB MiB is needed"
    }
    if ($hasAndroid) { Fail 'ESP 上已经有 Android 的启动项 —— 已经装过了' 'there are already Android boot entries on the ESP - already installed' }
    Say "ESP 空闲 $freeMiB MiB（要 $EspNeedMiB）" "ESP free $freeMiB MiB (need $EspNeedMiB)"

    $live = Get-Volume -FileSystemLabel $LiveLabel -ErrorAction SilentlyContinue
    $state = [ordered]@{ version = 1; shrinkDrive = $ShrinkDrive; shrunkBytes = 0; bcd = $null; fallback = [bool]$UseFallbackPath; loaderConfCreated = $false }
    if (Test-Path $StateFile) {
        $old = Get-Content $StateFile -Raw | ConvertFrom-Json
        foreach ($k in 'shrunkBytes', 'bcd', 'loaderConfCreated') { if ($old.PSObject.Properties[$k]) { $state[$k] = $old.$k } }
    }

    if ($live) {
        Say "已经有 $LiveLabel 分区（上次运行留下的）—— 不再压缩，只刷新里面的文件" "a $LiveLabel partition already exists (from an earlier run) - not shrinking again, just refreshing its files"
    } elseif ($state.shrunkBytes -gt 0) {
        # 上次缩成了、分区没建成（断电 / 报错）：【不能再缩一次】，直接在缩出来的地方建
        Say "上次已经缩过 $($ShrinkDrive):（$([math]::Round($state.shrunkBytes / 1GB, 1)) GiB）—— 不再压缩" "$($ShrinkDrive): was already shrunk last time - not shrinking again"
        $live = New-LiveVolume $disk (Get-Partition -DriveLetter $ShrinkDrive)
    } else {
        Step "2/5 压缩 $($ShrinkDrive):" "2/5 Shrinking $($ShrinkDrive):"
        $sup = Get-PartitionSupportedSize -DriveLetter $ShrinkDrive
        $want = [long]$AndroidGiB * 1GB + [long]$LiveMiB * 1MB
        $target = Get-ShrinkTarget $shr.Size $sup.SizeMin $want ([long]$WindowsKeepGiB * 1GB)
        if (-not $target) {
            $can = [math]::Floor(($shr.Size - $sup.SizeMin - [long]$WindowsKeepGiB * 1GB) / 1GB)
            Fail "$($ShrinkDrive): 缩不出 $AndroidGiB GiB + $LiveMiB MiB（最多约 $can GiB，还要给 Windows 留 $WindowsKeepGiB GiB）。可以用 -AndroidGiB 调小，或先清理 $($ShrinkDrive):" "cannot shrink $($ShrinkDrive): by that much (about $can GiB at most, keeping $WindowsKeepGiB GiB for Windows). Use a smaller -AndroidGiB"
        }
        Say ("{0}: {1:N1} GiB -> {2:N1} GiB；缩出 {3} GiB 给 Android + {4} MiB 给安装器" -f $ShrinkDrive, ($shr.Size / 1GB), ($target / 1GB), $AndroidGiB, $LiveMiB) `
            ("{0}: {1:N1} GiB -> {2:N1} GiB; {3} GiB for Android + {4} MiB for the installer" -f $ShrinkDrive, ($shr.Size / 1GB), ($target / 1GB), $AndroidGiB, $LiveMiB)
        Confirm-Yes "即将压缩 $($ShrinkDrive):（Windows 自己的“压缩卷”，不删文件），并新建分区 $LiveLabel。建议先备份重要数据。" "About to shrink $($ShrinkDrive): (Windows' own Shrink Volume; no files are deleted) and create partition $LiveLabel. Back up important data first."
        Resize-Partition -DriveLetter $ShrinkDrive -Size $target
        $state.shrunkBytes = $shr.Size - $target
        Save-State $state
        $live = New-LiveVolume $disk (Get-Partition -DriveLetter $ShrinkDrive)
    }
    $lp = $live | Get-Partition
    if (-not $lp.DriveLetter -or $lp.DriveLetter -eq [char]0) { $lp | Add-PartitionAccessPath -AssignDriveLetter; $lp = $live | Get-Partition }
    $lroot = "$($lp.DriveLetter):"

    Say "拷贝 live 系统到 $lroot" "copying the live system to $lroot"
    Copy-Item -Recurse -Force -Path (Join-Path $here 'live\*') -Destination "$lroot\"
    $payload = Join-Path $here 'payload'
    if (Test-Path (Join-Path $payload 'super.img.zst')) {
        Say '带上安装载荷（离线安装，不用联网）' 'including the install payload (offline install)'
        New-Item -ItemType Directory -Force -Path "$lroot\gaokun3\payload" | Out-Null
        Copy-Item -Force -Path (Join-Path $payload '*') -Destination "$lroot\gaokun3\payload\"
    } else {
        Say '没有安装载荷 —— 安装器会从网络下载（要先连上 WiFi）' 'no install payload - the installer will download it (needs WiFi)'
    }
    foreach ($rel in 'gaokun3\live.squashfs', 'gaokun3\initramfs.img') {
        $a = (Get-FileHash -Algorithm SHA256 (Join-Path $here "live\$rel")).Hash
        $b = (Get-FileHash -Algorithm SHA256 "$lroot\$rel").Hash
        if ($a -ne $b) { Fail "拷到 $LiveLabel 的 $rel 校验不对" "$rel on $LiveLabel does not verify" }
    }

    if ($Wifi -ne 'none') {
        # ⚠️ 不放 %TEMP%：用户名带空格时 folder="…" 会被拆开；这个目录里是【明文】密码，finally 里删
        $tmp = Join-Path $DataDir ('wlan-' + [guid]::NewGuid())
        New-Item -ItemType Directory -Force -Path $tmp | Out-Null
        try {
            & netsh.exe wlan export profile key=clear folder="$tmp" | Out-Null
            $current = @()
            if ($Wifi -eq 'current') { $current = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
            $blocks = @()
            foreach ($f in Get-ChildItem -Path $tmp -Filter '*.xml') {
                $x = New-Object xml; $x.Load($f.FullName)   # 按文件自己声明的编码读
                $nm = $x.WLANProfile.name
                if ($Wifi -eq 'current' -and $current -notcontains $nm) { continue }
                $b = ConvertTo-WpaNetwork $x
                if ($b) { $blocks += $b } else { Warn "WiFi「$nm」的加密方式不支持（企业网 / WEP），跳过" "WiFi '$nm' uses an unsupported security type, skipped" }
            }
            if ($blocks.Count -gt 0) {
                $conf = ($blocks -join "`n`n") + "`n"
                [IO.File]::WriteAllText("$lroot\gaokun3\wpa_supplicant.conf", $conf, (New-Object Text.UTF8Encoding($false)))
                Say "带上了 $($blocks.Count) 个 WiFi（WPA2 写的是推导出的 PSK，不是明文密码）" "included $($blocks.Count) WiFi network(s) (WPA2 as a derived PSK, not the password)"
            } else {
                Say '没有可带的 WiFi —— 到安装器里再连' 'no WiFi to include - connect in the installer'
            }
        } finally { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue $tmp }
    }
    # 装完就收回盘符：别让它出现在资源管理器里被误删
    $lp | Remove-PartitionAccessPath -AccessPath "$lroot\"

    Step '4/5 ESP：systemd-boot 与启动项' '4/5 ESP: systemd-boot and the boot entry'
    $esp = Mount-Esp
    try {
        New-Item -ItemType Directory -Force -Path "$esp\EFI\gaokun3", "$esp\loader\entries" | Out-Null
        Copy-Item -Force -Path (Join-Path $here 'esp\EFI\gaokun3\*') -Destination "$esp\EFI\gaokun3\"
        Copy-Item -Force -Path (Join-Path $here 'esp\loader\entries\gaokun3-live.conf') -Destination "$esp\loader\entries\"
        if (-not (Test-Path "$esp\loader\loader.conf")) {
            [IO.File]::WriteAllText("$esp\loader\loader.conf", (Format-LoaderConf), (New-Object Text.UTF8Encoding($false)))
            $state.loaderConfCreated = $true
        }
        if ($UseFallbackPath) {
            $fb = "$esp\EFI\Boot\bootaa64.efi"
            New-Item -ItemType Directory -Force -Path "$esp\EFI\Boot" | Out-Null
            if ((Test-Path $fb) -and -not (Test-Path "$fb.before-gaokun3")) { Copy-Item $fb "$fb.before-gaokun3" }
            Copy-Item -Force "$esp\EFI\gaokun3\systemd-bootaa64.efi" $fb
            Say '回落路径 \EFI\Boot\bootaa64.efi 已换成 systemd-boot（原件留 .before-gaokun3）' 'the fallback \EFI\Boot\bootaa64.efi is now systemd-boot (original kept as .before-gaokun3)'
        }
    } finally { Dismount-Esp $esp }
    Save-State $state

    Step '5/5 下一次开机进安装器' '5/5 Boot the installer next time'
    if ($UseFallbackPath) {
        Say '开机会出现 systemd-boot 菜单：默认进安装器，Windows Boot Manager 也在菜单里。' 'The systemd-boot menu will appear: the installer is the default; Windows Boot Manager is listed too.'
    } else {
        if (-not $state.bcd) {
            $out = Invoke-Bcd @('/copy', '{bootmgr}', '/d', $EntryTitle)
            $state.bcd = Get-BcdGuid $out
            if (-not $state.bcd) { Fail "bcdedit /copy 的输出里找不到 GUID：$out" "no GUID in the bcdedit /copy output: $out" }
            Save-State $state
        }
        Invoke-Bcd @('/set', $state.bcd, 'path', '\EFI\gaokun3\systemd-bootaa64.efi') | Out-Null
        Invoke-Bcd @('/set', '{fwbootmgr}', 'displayorder', $state.bcd, '/addlast') | Out-Null
        Invoke-Bcd @('/set', '{fwbootmgr}', 'bootsequence', $state.bcd) | Out-Null
        Say "只有下一次开机进安装器（固件启动项 $($state.bcd)）；默认启动项没动。" "Only the next boot goes to the installer (firmware entry $($state.bcd)); the default is unchanged."
        Warn 'bcdedit 的"只下一次"在这台机器的固件上还没验证过。重启后如果直接进了 Windows，改用 -UseFallbackPath 再运行一次。' "bcdedit's one-time boot has not been verified on this machine's firmware. If the next boot goes straight to Windows, run again with -UseFallbackPath."
    }
    Say '在安装器里选"保留现有系统"。不想装了：直接重启回 Windows，再运行本脚本加 -Uninstall。' 'In the installer choose "Keep the current system". Changed your mind: reboot into Windows and run this with -Uninstall.'
    if (-not $NoReboot) {
        $a = Read-Host (T '现在重启吗？(y/N)' 'Restart now? (y/N)')
        if ($a -eq 'y' -or $a -eq 'Y') { Restart-Computer }
    }
}

# 被 dot-source 时（test-setup.ps1）只加载函数，不跑主流程
if ($MyInvocation.InvocationName -ne '.') {
    if ($Uninstall) { Invoke-Uninstall } else { Invoke-Setup }
}
