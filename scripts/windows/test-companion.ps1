# Windows 伴随工具（设计稿 §4.9.15，S12）的测试。由 test-setup.ps1 dot-source：共用它的 Check、$here、$target、$Fixtures，
# 以及已经加载进来的 gaokun3-setup.ps1 的全部函数。
#
# 桩的办法：同名函数覆盖 cmdlet / 外部程序（PowerShell 的命令解析是 函数 > cmdlet）。ESP = 临时目录，固件变量 = 内存里的表，
# 分区 = test-fixtures.sh 用真 sgdisk / mkfs 造的盘镜像 + 一张"Windows 看到的"分区表。测的是我们自己的判定、顺序与"不碰什么"；
# Windows 本身怎么做（固件变量能不能写、schtasks 的权限、Remove-Partition 的行为……）【测不了】，只能等 D4 / D5 / D6。

$TMP = Join-Path ([IO.Path]::GetTempPath()) ('gk3t-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $TMP | Out-Null
function NP([string]$p) { return ($p -replace '\\', '/') }
function WF([string]$Path, [string]$Text) {
    $p = NP $Path
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $p) | Out-Null
    [IO.File]::WriteAllText($p, $Text)
}
function FH([string]$Path) { $p = NP $Path; if (Test-Path -LiteralPath $p) { return (Get-FileHash -Algorithm SHA256 -LiteralPath $p).Hash } return $null }
function EH([string]$Rel) { return (FH (Join-Path $script:Esp $Rel)) }
function Ex([string]$Rel) { return (Test-Path -LiteralPath (NP (Join-Path $script:Esp $Rel))) }
function TreeHash([string]$Dir) {
    $d = NP $Dir
    if (-not (Test-Path -LiteralPath $d)) { return 'absent' }
    return (@(Get-ChildItem -LiteralPath $d -Recurse -File | Sort-Object FullName | ForEach-Object { $_.FullName.Substring($d.Length) + '=' + (Get-FileHash -LiteralPath $_.FullName).Hash }) -join ';')
}

Write-Host '═══ 伴随工具：静态检查 ═══'
$t2 = $null; $e2 = $null
$ast2 = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$t2, [ref]$e2)
# "$变量中文"：PowerShell 的变量名可以含 Unicode 字母，紧跟的中文会被吃进变量名（StrictMode 下直接报错，否则静默变空）
$nv = $ast2.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -match '[^\x00-\x7f]' }, $true)
Check '变量名里没有非 ASCII（防"$变量紧跟中文"被吃进变量名）' ($nv.Count -eq 0) (($nv | ForEach-Object { "第 $($_.Extent.StartLineNumber) 行：$($_.Extent.Text)" }) -join '; ')
$cs = ''
try { Add-Type -TypeDefinition $NativeSource -Language CSharp -CompilerOptions '-langversion:5' } catch { $cs = [string]$_ }
Check 'P/Invoke 的 C# 按 C# 5 编译通过（Windows PowerShell 5.1 的 Add-Type 用 .NET Framework 自带的 C# 5 编译器）' ($cs -eq '') $cs
$neg = $false
try { Add-Type -TypeDefinition 'public static class GkLv6Probe { public static int F() => 1; }' -CompilerOptions '-langversion:5' } catch { $neg = $true }
Check '反例：C# 6 的写法在 -langversion:5 下确实编译不过（不然上一条说明不了什么）' $neg
Check 'Gk3Native 有 GetVar / SetVar / EnablePrivilege / ReadDisk' ($null -ne ('Gk3Native' -as [type]) -and @('GetVar', 'SetVar', 'EnablePrivilege', 'ReadDisk' | Where-Object { -not ([Gk3Native].GetMethod($_)) }).Count -eq 0)
foreach ($api in 'GetFirmwareEnvironmentVariableExW', 'SetFirmwareEnvironmentVariableExW', 'AdjustTokenPrivileges', 'SeSystemEnvironmentPrivilege', 'CreateFileW') {
    Check "用到的 Windows API 名照微软文档拼：$api" ($NativeSource.Contains($api) -or (Get-Content -Raw $target).Contains($api))
}

Write-Host '═══ 伴随工具：LoaderEntryDefault 的分类（与 tools/gk3boot/test/test_dual.c:67-75 同一组向量）═══'
$vec = @(
    @($null, 'absent'), @('auto-windows', 'windows'), @('Auto-Windows', 'windows'), @('gk3-windows.conf', 'windows'),
    @('gk3-windows', 'other'), @('gk3boot-android-a.conf', 'other'), @('@saved', 'other'), @('auto-windows*', 'other'), @('', 'other'),
    @('GK3-WINDOWS.CONF', 'windows'), @('auto-wındows', 'other')
)
foreach ($v in $vec) { $got = Get-DefVarClass $v[0]; Check "classify('$($v[0])') = $($v[1])" ($got -eq $v[1]) "得到 $got" }

Write-Host '═══ 伴随工具：变量的字节格式（UTF-16LE + NUL，同 gk3boot.c loader_var_set）═══'
Check "'ab' → 61 00 62 00 00 00" ((ConvertTo-HexString (ConvertTo-LoaderVarBytes 'ab')) -eq '610062000000')
Check "'auto-windows' 是 26 字节" ((ConvertTo-LoaderVarBytes 'auto-windows').Length -eq 26)
Check '解码到第一个 NUL 为止' ((ConvertFrom-LoaderVarBytes ([byte[]](0x61, 0, 0x62, 0, 0, 0, 0x63, 0))) -eq 'ab')
Check '0x20–0x7e 以外记成 ?（同 gk3_ucs2_to_ascii）' ((ConvertFrom-LoaderVarBytes ([byte[]](0x41, 0, 0xe9, 0, 0x0a, 0, 0x42, 0))) -eq 'A??B')
Check '往返：*-android-a.conf' ((ConvertFrom-LoaderVarBytes (ConvertTo-LoaderVarBytes '*-android-a.conf')) -eq '*-android-a.conf')

Write-Host '═══ 伴随工具：loader.conf / 条目名 / 关机类型 ═══'
Check 'loader.conf 的 default：后出现的覆盖先出现的、注释不算（boot.c:1242-1248）' ((Get-LoaderConfDefault "timeout 5`r`ndefault a.conf`r`n# default x.conf`r`ndefault *-android-b.conf`r`n") -eq '*-android-b.conf')
Check 'loader.conf 没有 default → $null' ($null -eq (Get-LoaderConfDefault "timeout 5`n"))
foreach ($v in @(@('*-android-a.conf', $true), @('0123456789abcdef0123456789abcdef-android-b.conf', $true), @('gk3boot-android-a.conf', $true),
                 @('gaokun3-live.conf', $false), @('auto-windows', $false), @('*-android-*.conf', $false), @('', $false), @('@saved', $false))) {
    Check "重启到 Android 的目标 '$($v[0])' → $($v[1])" ((Test-AndroidEntryPattern $v[0]) -eq $v[1])
}
$mid = '0123456789abcdef0123456789abcdef'
foreach ($v in @(@('gaokun3-live.conf', $true), @('gk3boot-android-a+3.conf', $true), @('gk3boot-android-b+2-1.conf', $true), @('gk3prev-android-a.conf', $true),
                 @('gk3-windows.conf', $true), @('gk3boot-tools.conf', $true), @("$mid-android-a.conf", $true), @("$mid-rescue.conf", $true),
                 @("$mid-rescue-b.conf", $true), @("$mid-android-b.conf.disabled", $true), @("$mid-recovery-a.conf", $true),
                 @('arch.conf', $false), @("$mid-6.1.0-1-arm64.conf", $false), @('loader.conf', $false), @('auto-windows', $false))) {
    Check "条目 $($v[0]) 是我们的 = $($v[1])" ((Test-OurEntryName $v[0]) -eq $v[1])
}
foreach ($v in @(@('restart', 'restart'), @('power off', 'poweroff'), @('重新启动', 'restart'), @('关机', 'poweroff'), @('', 'unknown'), @('Neustart', 'unknown'))) {
    Check "Event 1074 关机类型 '$($v[0])' → $($v[1])（判据未验证，D4 ⑨）" ((Get-ShutdownKind $v[0]) -eq $v[1])
}

Write-Host '═══ 伴随工具：计划任务 XML / 开始菜单项（只能触发固定动作，传不进参数）═══'
$tns = 'http://schemas.microsoft.com/windows/2004/02/mit/task'
function TX([string]$Xml) { $x = New-Object xml; $x.LoadXml($Xml); $m = New-Object System.Xml.XmlNamespaceManager($x.NameTable); $m.AddNamespace('t', $tns); return @($x, $m) }
$defs = Get-CompanionTaskDefs $false
Check 'U25 默认关：不建 WindowsShutdown 任务' ((@($defs.Keys) -join ',') -eq 'BootCheck,Notify,RebootToAndroid,DefaultAndroid,DefaultWindows') (@($defs.Keys) -join ',')
$defs2 = Get-CompanionTaskDefs $true
Check 'U25 打开时多一个 WindowsShutdown' ($defs2.Contains('WindowsShutdown'))
$argRe = '^-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "[^"]*gaokun3-setup\.ps1" -(BootCheck|Notify|TaskAction (RebootToAndroid|DefaultAndroid|DefaultWindows|WindowsShutdown))$'
foreach ($k in @($defs2.Keys)) {
    $ok = $true; $why = ''
    try {
        $p = TX $defs2[$k]
        $a = $p[0].SelectSingleNode('//t:Actions/t:Exec/t:Arguments', $p[1]).InnerText
        $c = $p[0].SelectSingleNode('//t:Actions/t:Exec/t:Command', $p[1]).InnerText
        if ($a -notmatch $argRe) { $ok = $false; $why = "参数：$a" }
        if ($c -notmatch 'System32\\WindowsPowerShell\\v1\.0\\powershell\.exe$') { $ok = $false; $why += " 命令：$c" }
    } catch { $ok = $false; $why = [string]$_ }
    Check "任务 $k：XML 解析通过、命令是全路径 powershell.exe、参数是固定的那几个之一" $ok $why
}
$p = TX $defs['BootCheck']
Check 'BootCheck：开机触发、以 SYSTEM（S-1-5-18）跑、没有放宽的权限' ($null -ne $p[0].SelectSingleNode('//t:Triggers/t:BootTrigger', $p[1]) -and $p[0].SelectSingleNode('//t:Principal/t:UserId', $p[1]).InnerText -eq 'S-1-5-18' -and $null -eq $p[0].SelectSingleNode('//t:SecurityDescriptor', $p[1]))
$p = TX $defs['Notify']
Check 'Notify：登录触发、以 Users 组（S-1-5-32-545）、最低权限跑' ($null -ne $p[0].SelectSingleNode('//t:Triggers/t:LogonTrigger', $p[1]) -and $p[0].SelectSingleNode('//t:Principal/t:GroupId', $p[1]).InnerText -eq 'S-1-5-32-545' -and $p[0].SelectSingleNode('//t:Principal/t:RunLevel', $p[1]).InnerText -eq 'LeastPrivilege')
$p = TX $defs['RebootToAndroid']
Check 'RebootToAndroid：没有触发器（只能按需跑）、SYSTEM、带让用户能 /Run 的 SecurityDescriptor（是否生效未验证）' ($null -eq $p[0].SelectSingleNode('//t:Triggers', $p[1]) -and $p[0].SelectSingleNode('//t:Principal/t:UserId', $p[1]).InnerText -eq 'S-1-5-18' -and $p[0].SelectSingleNode('//t:SecurityDescriptor', $p[1]).InnerText -match '\(A;;GRGX;;;AU\)')
$p = TX $defs2['WindowsShutdown']
$sub = $p[0].SelectSingleNode('//t:EventTrigger/t:Subscription', $p[1]).InnerText
$subOk = $false; try { $sx = New-Object xml; $sx.LoadXml($sub); $subOk = $sx.QueryList.Query.Select.'#text' -match "Provider\[@Name='User32'\] and EventID=1074" } catch { }
Check 'WindowsShutdown：事件触发，订阅是合法的 QueryList、筛 System 日志 User32 的 1074' $subOk $sub
$sc = @(Get-ShortcutDefs)
Check '开始菜单 7 项：重启到 Android / 默认 Android / 默认 Windows / 修复 / 检查 / 仅暂停 BitLocker / 卸载 Android' ($sc.Count -eq 7)
Check '前三项不提权：powershell -File … -Trigger <固定动作>' (@($sc[0..2] | Where-Object { $_.Target -notmatch 'powershell\.exe$' -or $_.Arguments -notmatch ' -Trigger (RebootToAndroid|DefaultAndroid|DefaultWindows)$' }).Count -eq 0)
Check '后四项经 gaokun3-setup.cmd（请求管理员）' (@($sc[3..6] | Where-Object { $_.Target -notmatch 'gaokun3-setup\.cmd$' }).Count -eq 0)

Write-Host '═══ 伴随工具：登录时弹哪些 ═══'
$iss = @([ordered]@{ id = 'bootaa64-replaced'; key = 'h1' }, [ordered]@{ id = 'bios-changed'; key = '2.16->2.17' }, [ordered]@{ id = 'default-reset'; key = 't1' })
$pend = @(Get-PendingNotices $iss @('bootaa64-replaced|h1', 'bios-changed|2.16->2.17'))
Check '确认过的不再弹；BOOTAA64 被换掉那一条每次都弹（不可关）' ((@($pend | ForEach-Object { $_['id'] }) -join ',') -eq 'bootaa64-replaced,default-reset')
foreach ($id in 'bootaa64-replaced', 'bootaa64-other', 'sdboot-missing', 'default-reset', 'bios-changed', 'secureboot-on', 'esp-unreadable') {
    $t = Get-NoticeText ([ordered]@{ id = $id; key = 'k'; detail = 'd' })
    Check "提示文案 $id（只有 bootaa64-replaced 给'现在修复'）" ($t.Count -eq 3 -and [bool]$t[2] -eq ($id -eq 'bootaa64-replaced') -and $t[1].Length -gt 10)
}

# ══ 模拟环境 ══════════════════════════════════════════════════════════════════

$script:UseZh = $true
$Yes = $true; $NoReboot = $true; $Hibernate = 'keep'; $NoExtend = $false; $ShrinkDrive = 'D'
$DataDir = NP (Join-Path $TMP 'ProgramData/gaokun3')
$StateFile = Join-Path $DataDir 'windows-setup.json'
$CompanionFile = Join-Path $DataDir 'companion.json'
$StatusFile = Join-Path $DataDir 'boot-check.json'
$LogFile = Join-Path $DataDir 'companion.log'
$InstallDir = NP (Join-Path $TMP 'ProgramFiles/gaokun3')
$StartMenuDir = NP (Join-Path $TMP 'StartMenu/gaokun3')
$SrcDir = NP (Join-Path $TMP 'src')
New-Item -ItemType Directory -Force -Path $SrcDir | Out-Null
Copy-Item -LiteralPath $target -Destination (Join-Path $SrcDir 'gaokun3-setup.ps1')
Copy-Item -LiteralPath (Join-Path $here 'gaokun3-setup.cmd') -Destination (Join-Path $SrcDir 'gaokun3-setup.cmd')
$SelfPath = Join-Path $SrcDir 'gaokun3-setup.ps1'
$script:Quiet = $false
$script:QOut = New-Object System.Collections.ArrayList
$script:LastErr = ''
$script:EspN = 0

function Write-Host { if ($script:Quiet) { if ($args.Count -gt 0) { [void]$script:QOut.Add([string]$args[0]) } } else { Microsoft.PowerShell.Utility\Write-Host @args } }
function Q([scriptblock]$Block) {
    $script:Quiet = $true; $script:QOut.Clear(); $script:LastErr = ''
    try { return (& $Block) } catch { $script:LastErr = [string]$_.Exception.Message; return 'THREW' } finally { $script:Quiet = $false }
}
function Reset-Fake {
    $script:Vars = @{}; $script:VarFail = @{ get = 0; set = 0 }
    $script:Calls = New-Object System.Collections.ArrayList
    $script:Reg = @{ HiberbootEnabled = 1; HibernateEnabled = 1 }
    $script:Bios = '2.16'; $script:SB = $false; $script:BL = 'On'
    $script:TaskXml = @{}; $script:Shortcuts = @(); $script:BoxAnswer = $false; $script:ShutType = $null; $script:RunFails = $false
    $script:Parts = @(); $script:UsbParts = @(); $script:DiskImg = $null; $script:DiskEnd = 0
    $script:FwPrivOk = $true
    foreach ($d in $DataDir, $InstallDir, $StartMenuDir) { Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $d }
}
function SetVarT([string]$Name, [string]$Value) { $script:Vars[$Name] = @{ Data = (ConvertTo-LoaderVarBytes $Value); Attr = 7 } }
function GetVarT([string]$Name) { if ($script:Vars.ContainsKey($Name)) { return (ConvertFrom-LoaderVarBytes $script:Vars[$Name].Data) } return $null }
function Called([string]$Like) { return @($script:Calls | Where-Object { $_ -like $Like }).Count }

# 假 ESP。字节内容：bootmgfw = 当前的 Windows 启动管理器，.before-gaokun3 = 装机那天的旧拷贝（故意不同）
function New-FakeEsp {
    param([switch]$Android, [switch]$Gk3boot, [ValidateSet('sdboot', 'windows', 'other', 'missing')][string]$BootAA64 = 'sdboot',
          [switch]$Foreign, [switch]$Live, [switch]$NoBootmgfw, [switch]$NoBackup, [switch]$WinEntry, [string]$Default = '*-android-a.conf')
    $script:EspN++
    $e = NP (Join-Path $TMP "esp-$($script:EspN)")
    if (-not $NoBootmgfw) { WF "$e/EFI/Microsoft/Boot/bootmgfw.efi" 'WINDOWS-BOOT-MANAGER v2' }
    WF "$e/EFI/Microsoft/Boot/BCD" 'bcd-hive'
    WF "$e/EFI/UpdateCapsule/cap.bin" 'capsule'
    WF "$e/Persisted_Capsules.bin" 'persisted'
    WF "$e/OneKeyLog.txt" 'onekey'
    $boot = @{ sdboot = 'SYSTEMD-BOOT 257.13'; windows = 'WINDOWS-BOOT-MANAGER v2'; other = 'GRUB-ARM64'; missing = $null }[$BootAA64]
    if ($Android) {
        WF "$e/EFI/systemd/systemd-bootaa64.efi" 'SYSTEMD-BOOT 257.13'
        if (-not $NoBackup) { WF "$e/EFI/Boot/bootaa64.efi.before-gaokun3" 'WINDOWS-BOOT-MANAGER v1' }
        WF "$e/loader/loader.conf" "timeout 15`nconsole-mode keep`neditor no`ndefault $Default`n"
        foreach ($s in 'a', 'b') { WF "$e/loader/entries/$mid-android-$s.conf" "title Android $s`nlinux /$mid/android/slot_$s/Image`n"; WF "$e/$mid/android/slot_$s/Image" "kernel-$s" }
        WF "$e/loader/entries/$mid-rescue.conf" 'title rescue'
        WF "$e/$mid/rescue/initramfs.img" 'rescue-initrd'
    }
    if ($boot) { WF "$e/EFI/Boot/bootaa64.efi" $boot }
    if ($Gk3boot) { WF "$e/EFI/gk3boot/1.0/gk3boot.efi" 'gk3boot'; WF "$e/loader/entries/gk3boot-android-a+3.conf" 'title Android'; WF "$e/loader/entries/gk3boot-tools.conf" 'title tools' }
    if ($WinEntry) { WF "$e/loader/entries/gk3-windows.conf" "title Windows`nefi /EFI/Microsoft/Boot/bootmgfw.efi`n" }
    if ($Live) { WF "$e/EFI/gaokun3/Image" 'live-kernel'; WF "$e/loader/entries/gaokun3-live.conf" 'title gaokun3 installer' }
    if ($Foreign) {
        WF "$e/loader/entries/arch.conf" 'title Arch'
        WF "$e/ffffffffffffffffffffffffffffffff/6.1/linux" 'arch-kernel'
        WF "$e/loader/loader.conf.before-gaokun3" "default arch.conf`n"
    }
    return $e
}

function Load-Disk([string]$Variant) {
    $j = Get-Content -Raw -LiteralPath (Join-Path $Fixtures "disk-$Variant.json") | ConvertFrom-Json
    $script:DiskImg = Join-Path $Fixtures "disk-$Variant.img"
    $script:DiskEnd = (Get-Item -LiteralPath $script:DiskImg).Length
    $letters = @{ C = 'C'; D = 'D'; live = 'L' }
    $script:Parts = @(foreach ($p in $j.partitions) {
        $dl = [char]0; if ($letters.ContainsKey($p.role)) { $dl = [char]$letters[$p.role] }
        $label = ''; if ($p.role -eq 'live') { $label = 'GK3LIVE' }
        [pscustomobject]@{ DiskNumber = 0; PartitionNumber = [int]$p.number; Guid = "{$($p.guid)}"; GptType = "{$($p.typeGuid)}"
                           Offset = [long]$p.firstLba * 512; Size = ([long]$p.lastLba - [long]$p.firstLba + 1) * 512
                           DriveLetter = $dl; Label = $label; LiveContent = ($p.role -eq 'live'); Role = $p.role }
    })
    # U 盘介质的卷标也是 GK3LIVE：放一个在 1 号盘上，确认谁都不碰它
    $script:UsbParts = @([pscustomobject]@{ DiskNumber = 1; PartitionNumber = 1; Guid = '{aaaaaaaa-0000-4000-8000-000000000001}'; GptType = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
                                            Offset = 1MB; Size = 1GB; DriveLetter = [char]'U'; Label = 'GK3LIVE'; LiveContent = $true; Role = 'usb' })
    return $j
}
function Num([string]$Role) { return @($script:Parts | Where-Object { $_.Role -eq $Role })[0].PartitionNumber }

# ── 桩 ──
function Get-SpecialDir([string]$Name, [string]$Fallback) { return (NP (Join-Path $TMP $Fallback)) }
function Mount-Esp { [void]$script:Calls.Add('mount-esp'); return $script:Esp }
function Dismount-Esp([string]$Esp) { }
function Test-Admin { return $true }
function Get-FwVarRaw([string]$Name) {
    [void]$script:Calls.Add("getvar $Name")
    if ($script:VarFail['get']) { return @{ Code = $script:VarFail['get']; Data = $null; Attr = 0 } }
    if ($script:Vars.ContainsKey($Name)) { return @{ Code = 0; Data = [byte[]]$script:Vars[$Name].Data; Attr = $script:Vars[$Name].Attr } }
    return @{ Code = 203; Data = $null; Attr = 0 }
}
function Set-FwVarRaw([string]$Name, [byte[]]$Data) {
    $len = 0; if ($Data) { $len = $Data.Length }
    [void]$script:Calls.Add("setvar $Name $len")
    if ($script:VarFail['set']) { return $script:VarFail['set'] }
    if ($len -eq 0) { if (-not $script:Vars.ContainsKey($Name)) { return 203 }; $script:Vars.Remove($Name); return 0 }
    $script:Vars[$Name] = @{ Data = $Data; Attr = 7 }
    return 0
}
function Invoke-Native([string]$Exe, [string[]]$ArgList) {
    [void]$script:Calls.Add("$Exe $($ArgList -join ' ')")
    if ($Exe -eq 'schtasks.exe' -and $ArgList[0] -eq '/Create') { $script:TaskXml[$ArgList[2]] = [IO.File]::ReadAllText((NP $ArgList[4])) }
    if ($Exe -eq 'schtasks.exe' -and $ArgList[0] -eq '/Run') {
        if ($script:RunFails) { return [pscustomobject]@{ Code = 1; Out = 'ERROR: Access is denied.' } }
        $null = Invoke-TaskAction ($ArgList[2] -replace '^\\gaokun3\\', '')     # 模拟 SYSTEM 任务同步跑完
    }
    if ($Exe -eq 'powercfg.exe') { $script:Reg['HibernateEnabled'] = [int]($ArgList[1] -eq 'on') }
    if ($Exe -eq 'manage-bde.exe') { [void]$script:Calls.Add("manage-bde-at bootaa64=$(EH 'EFI/Boot/bootaa64.efi')") }
    return [pscustomobject]@{ Code = 0; Out = '' }
}
function Invoke-Bcd([string[]]$BcdArgs) { [void]$script:Calls.Add("bcdedit $($BcdArgs -join ' ')"); return '' }
function Get-FastStartup { return $script:Reg['HiberbootEnabled'] }
function Set-FastStartup([int]$Value) { $script:Reg['HiberbootEnabled'] = $Value; [void]$script:Calls.Add("faststartup=$Value") }
function Get-HibernateEnabled { return $script:Reg['HibernateEnabled'] }
function Get-BiosVersion { return $script:Bios }
function Get-SecureBootOn { return $script:SB }
function New-Shortcut([string]$Path, [string]$Target, [string]$Arguments, [string]$Description) { $script:Shortcuts += , @($Path, $Target, $Arguments) }
function Show-Box([string]$Title, [string]$Text, [bool]$AskRepair) { [void]$script:Calls.Add("box $Title"); return $script:BoxAnswer }
function Start-Process { [CmdletBinding()] param($FilePath, $ArgumentList, $WindowStyle) [void]$script:Calls.Add("start $FilePath $ArgumentList") }
function Start-Sleep { [CmdletBinding()] param($Milliseconds, $Seconds) }
function Get-LastShutdownType { return $script:ShutType }
function Test-LivePartitionContent($Partition) { return [bool]$Partition.LiveContent }
function Read-DiskBytes([int]$Disk, [long]$Offset, [int]$Length) {
    $fs = [IO.File]::OpenRead((NP $script:DiskImg))
    try {
        [void]$fs.Seek($Offset, 'Begin')
        $b = New-Object byte[] $Length; $n = 0
        while ($n -lt $Length) { $r = $fs.Read($b, $n, $Length - $n); if ($r -le 0) { break }; $n += $r }
        return , $b
    } finally { $fs.Dispose() }
}
function Get-Partition {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$Volume, $DiskNumber, $DriveLetter, $PartitionNumber)
    process {
        $all = @($script:Parts) + @($script:UsbParts)
        if ($Volume) { return (@($all | Where-Object { $_.Guid -eq $Volume.PartGuid }) | Select-Object -First 1) }
        if ($PSBoundParameters.ContainsKey('DriveLetter')) {
            $p = @($all | Where-Object { [string]$_.DriveLetter -eq [string]$DriveLetter })
            if ($p.Count -eq 0) { throw "No MSFT_Partition objects found with property 'DriveLetter' equal to '$DriveLetter'." }
            return $p[0]
        }
        $r = $all
        if ($PSBoundParameters.ContainsKey('DiskNumber')) { $r = @($r | Where-Object { $_.DiskNumber -eq $DiskNumber }) }
        if ($PSBoundParameters.ContainsKey('PartitionNumber')) { $r = @($r | Where-Object { $_.PartitionNumber -eq $PartitionNumber }) }
        return $r
    }
}
function Get-Disk { [CmdletBinding()] param($Number) return [pscustomobject]@{ Number = $Number; LogicalSectorSize = 512; PartitionStyle = 'GPT' } }
function Get-Volume {
    [CmdletBinding()] param($FileSystemLabel)
    return @(@($script:Parts) + @($script:UsbParts) | Where-Object { $_.Label -eq $FileSystemLabel } | ForEach-Object { [pscustomobject]@{ FileSystemLabel = $_.Label; PartGuid = $_.Guid } })
}
function Remove-Partition {
    [CmdletBinding(SupportsShouldProcess = $true)] param($DiskNumber, $PartitionNumber)
    [void]$script:Calls.Add("remove-partition $DiskNumber $PartitionNumber")
    $script:Parts = @($script:Parts | Where-Object { -not ($_.DiskNumber -eq $DiskNumber -and $_.PartitionNumber -eq $PartitionNumber) })
}
function Resize-Partition {
    [CmdletBinding()] param($DriveLetter, $Size)
    [void]$script:Calls.Add("resize $DriveLetter $Size")
    foreach ($p in $script:Parts) { if ([string]$p.DriveLetter -eq [string]$DriveLetter) { $p.Size = $Size } }
}
function Get-PartitionSupportedSize {
    [CmdletBinding()] param($DriveLetter)
    $p = Get-Partition -DriveLetter $DriveLetter
    $next = @($script:Parts | Where-Object { $_.DiskNumber -eq $p.DiskNumber -and $_.Offset -gt $p.Offset } | Sort-Object Offset)
    $end = $script:DiskEnd; if ($next.Count -gt 0) { $end = $next[0].Offset }
    return [pscustomobject]@{ SizeMin = 1MB; SizeMax = $end - $p.Offset }
}
function Update-Disk { [CmdletBinding()] param($Number) }
function Remove-PartitionAccessPath {
    [CmdletBinding()] param([Parameter(ValueFromPipeline)]$InputObject, $AccessPath)
    process { [void]$script:Calls.Add("remove-letter $($InputObject.DiskNumber):$($InputObject.PartitionNumber) $AccessPath"); $InputObject.DriveLetter = [char]0 }
}
# BitLocker 模块的桩（家庭版没有这个模块：测试里删掉这两个函数来模拟）
function Get-BitLockerVolume { [CmdletBinding()] param($MountPoint) return [pscustomobject]@{ ProtectionStatus = $script:BL } }
function Suspend-BitLocker { [CmdletBinding()] param($MountPoint, $RebootCount) [void]$script:Calls.Add("suspend $MountPoint $RebootCount bootaa64=$(EH 'EFI/Boot/bootaa64.efi')") }

$haveFx = ($Fixtures -and (Test-Path -LiteralPath (Join-Path $Fixtures 'disk-normal.json')))
$hSd = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('SYSTEMD-BOOT 257.13')))).Hash
$hWin = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('WINDOWS-BOOT-MANAGER v2')))).Hash
$hWinOld = (Get-FileHash -InputStream ([IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('WINDOWS-BOOT-MANAGER v1')))).Hash

Write-Host '═══ 伴随工具：真 GPT 盘镜像（test-fixtures.sh：sgdisk / mkfs.ext4 / mkntfs 造的）═══'
Check "有盘镜像（-Fixtures $Fixtures）" $haveFx
if ($haveFx) {
    $j = Load-Disk 'normal'
    $gpt = @(Get-DiskGpt 0 512)
    Check "GPT 解析出 $($j.partitions.Count) 个分区" ($gpt.Count -eq $j.partitions.Count) "得到 $($gpt.Count)"
    $bad = @()
    foreach ($p in $j.partitions) {
        $g = @($gpt | Where-Object { $_.Index -eq $p.number })[0]
        if (-not $g -or $g.Guid -ne $p.guid -or $g.Type -ne $p.typeGuid -or [long]$g.FirstLba -ne [long]$p.firstLba -or [long]$g.LastLba -ne [long]$p.lastLba -or $g.Name -cne $p.name) { $bad += $p.number }
    }
    Check '每个分区的 GUID / 类型 / 首末扇区 / 名字与 sgdisk -i 读回的逐项相同' ($bad.Count -eq 0) "不同：$($bad -join ',')"
    $kinds = @{}
    foreach ($p in $script:Parts) { $kinds[$p.Role] = Get-ContentKind (Read-DiskBytes 0 $p.Offset 8192) }
    foreach ($v in @(@('C', 'ntfs'), @('D', 'ntfs'), @('winpe', 'ntfs'), @('esp', 'fat'), @('live', 'fat'), @('metadata', 'ext4'), @('userdata', 'ext4'), @('boot_a', 'android-boot'), @('super', 'lp'), @('misc', 'empty'))) {
        Check "内容识别：$($v[0]) → $($v[1])（mkfs 真造的）" ($kinds[$v[0]] -eq $v[1]) "得到 $($kinds[$v[0]])"
    }
    $bl = New-Object byte[] 8192; $bl[0] = 0xeb; $bl[1] = 0x58; $bl[2] = 0x90
    [Array]::Copy([Text.Encoding]::ASCII.GetBytes('-FVE-FS-'), 0, $bl, 3, 8)
    Check '内容识别：BitLocker（偏移 3 的 -FVE-FS-）' ((Get-ContentKind $bl) -eq 'bitlocker')
    $all = @($script:Parts)
    $dG = (@($all | Where-Object { $_.Role -eq 'D' })[0]).Guid
    $delR = @('live', 'misc', 'metadata', 'boot_a', 'boot_b', 'super', 'userdata')
    $del = @($all | Where-Object { $delR -contains $_.Role } | ForEach-Object { $_.Guid })
    $x = Get-ExtendPlan $all $dG $del
    Check '相邻：D: 后面紧跟 GK3LIVE + Android 的 7 个分区 → 可以扩' ($x.Adjacent -and @($x.Run).Count -eq 7 -and @($x.Stranded).Count -eq 0)
    $x = Get-ExtendPlan $all $dG @($all | Where-Object { $_.Role -ne 'live' -and $delR -contains $_.Role } | ForEach-Object { $_.Guid })
    Check '不删 GK3LIVE（内容没认出）时 D: 后面紧跟的是保留的分区 → 不扩' (-not $x.Adjacent -and $x.Reason -eq 'next-kept')
    foreach ($v in @(@('ntfsdata', 'userdata', 'ntfs'), @('ntfsdata', 'super', 'lp'), @('gap', 'super', 'lp'), @('gap', 'userdata', 'ext4'), @('gap', 'winpe', 'ntfs'))) {
        $null = Load-Disk $v[0]
        $p = @($script:Parts | Where-Object { $_.Role -eq $v[1] })[0]
        $k = Get-ContentKind (Read-DiskBytes 0 $p.Offset 8192)
        Check "盘镜像 $($v[0])：$($v[1]) → $($v[2])（夹具自己没串味）" ($k -eq $v[2]) "得到 $k"
    }
    $j = Load-Disk 'gap'
    $all = @($script:Parts)
    $x = Get-ExtendPlan $all (@($all | Where-Object { $_.Role -eq 'D' })[0]).Guid @($all | Where-Object { $delR -contains $_.Role } | ForEach-Object { $_.Guid })
    Check 'gap 布局：D: 后面是 WINPE → 不扩、原因 next-kept' (-not $x.Adjacent -and $x.Reason -eq 'next-kept')
}

Write-Host '═══ 伴随工具：删之前的断言 ═══'
function Cand([string]$n, [string]$kind = 'ext4', [string]$type = $LinuxFsType, [long]$size = 1MB, [bool]$ok = $true) {
    return [pscustomobject]@{ Name = $n; Type = $type; Guid = [guid]::NewGuid().ToString(); Offset = 0; Size = $size; Kind = $kind; OffsetOk = $ok }
}
$good = @((Cand 'misc' 'empty'), (Cand 'boot_a' 'android-boot'), (Cand 'boot_b' 'empty'), (Cand 'super' 'lp'), (Cand 'metadata'), (Cand 'userdata'))
$r = Test-RemovalCandidates $good
Check '正常的一组：没有错误（boot_b 全零只记一条说明）' ($r.Errors.Count -eq 0 -and $r.Notes.Count -eq 1) (($r.Errors + $r.Notes) -join '; ')
$cases = @(
    @('重名 userdata', ($good + (Cand 'userdata'))),
    @('userdata 是 basic data 类型', (@($good[0..4]) + (Cand 'userdata' 'ext4' 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7'))),
    @('userdata 里是 NTFS', (@($good[0..4]) + (Cand 'userdata' 'ntfs'))),
    @('super 里是 BitLocker', (@($good[0..2]) + (Cand 'super' 'bitlocker') + @($good[4..5]))),
    @('misc 8 MiB（超过 GK3_MISC_MIB）', (@((Cand 'misc' 'empty' $LinuxFsType 8MB)) + @($good[1..5]))),
    @('GPT 偏移与 Windows 看到的不一致', (@($good[0..4]) + (Cand 'userdata' 'ext4' $LinuxFsType 1MB $false))),
    @('boot / super 一个都认不出', @((Cand 'misc' 'empty'), (Cand 'boot_a' 'empty'), (Cand 'super' 'unknown'), (Cand 'userdata'))),
    @('一个 Android 分区都没有', @())
)
foreach ($c in $cases) { $r = Test-RemovalCandidates $c[1]; Check "拒绝：$($c[0])" ($r.Errors.Count -gt 0) }

# ── 开机自检 ──
Write-Host '═══ 伴随工具：开机自检（①BOOTAA64 ②LoaderEntryDefault ③BIOS）═══'
Reset-Fake; $script:Esp = New-FakeEsp -Live
$s = Q { Invoke-BootCheck }
Check '没装 Android：一个固件变量都不读不写、没有提示' ((Called 'getvar*') + (Called 'setvar*') -eq 0 -and -not $s.android -and @($s.issues).Count -eq 0)
Check '第一次只记 BIOS 基线' ((Read-Companion)['biosVersion'] -eq '2.16')

Reset-Fake; $script:Esp = New-FakeEsp -Android; SetVarT 'LoaderEntryDefault' 'gk3boot-android-a.conf'
$s = Q { Invoke-BootCheck }
Check '默认项钉在 Android 精确 id 上 → 删掉（= 默认 Android），提示 default-reset' ($null -eq (GetVarT 'LoaderEntryDefault') -and @($s.issues | Where-Object { $_.id -eq 'default-reset' -and $_.detail -eq 'gk3boot-android-a.conf' }).Count -eq 1)
Check 'BOOTAA64 = systemd-boot：没有 BOOTAA64 的提示' ($s.bootaa64 -eq 'ok' -and @($s.issues | Where-Object { $_.id -like 'bootaa64*' }).Count -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android; SetVarT 'LoaderEntryDefault' 'Auto-Windows'
$s = Q { Invoke-BootCheck }
Check '合法值 Auto-Windows 留着、不写' ((GetVarT 'LoaderEntryDefault') -eq 'Auto-Windows' -and (Called 'setvar*') -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android
$s = Q { Invoke-BootCheck }
Check '变量不存在：不写' ((Called 'setvar*') -eq 0 -and $s.loaderEntryDefault -eq 'absent')
Reset-Fake; $script:Esp = New-FakeEsp -Android; SetVarT 'LoaderEntryDefault' 'gk3boot-android-a.conf'; $script:VarFail['get'] = 5
$s = Q { Invoke-BootCheck }
Check '读不出（不是"不存在"）：不去删一个看不见的东西' ((Called 'setvar*') -eq 0 -and $s.loaderEntryDefault -eq 'unreadable' -and @($s.issues | Where-Object { $_.id -eq 'default-reset' }).Count -eq 0)
foreach ($v in @(@('windows', 'bootaa64-replaced'), @('missing', 'bootaa64-replaced'), @('other', 'bootaa64-other'))) {
    Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 $v[0]
    $s = Q { Invoke-BootCheck }
    Check "BOOTAA64 = $($v[0]) → 提示 $($v[1])，只通知不修" (@($s.issues | Where-Object { $_.id -eq $v[1] }).Count -eq 1 -and (Called 'suspend*') -eq 0)
}
Reset-Fake; $script:Esp = New-FakeEsp -Android; $script:SB = $true
$s = Q { Invoke-BootCheck }
Check '安全启动开着 → 提示 secureboot-on' (@($s.issues | Where-Object { $_.id -eq 'secureboot-on' }).Count -eq 1)
Reset-Fake; $script:Esp = New-FakeEsp -Android
$null = Q { Invoke-BootCheck }; $script:Bios = '2.17'
$s = Q { Invoke-BootCheck }
Check 'BIOS 2.16 → 2.17：提示 bios-changed' (@($s.issues | Where-Object { $_.id -eq 'bios-changed' -and $_.key -eq '2.16->2.17' }).Count -eq 1)
$s = Q { Invoke-BootCheck }
Check '下一次开机：这条事件留着（7 天），不重复' (@($s.issues | Where-Object { $_.id -eq 'bios-changed' }).Count -eq 1)
if ($haveFx) {
    Reset-Fake; $null = Load-Disk 'normal'; $script:Esp = New-FakeEsp -Android
    Write-JsonFile $StateFile ([ordered]@{ version = 1; shrinkDrive = 'D'; shrunkBytes = 512MB; bcd = '{6f0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b}'; fallback = $false; loaderConfCreated = $false; fastStartupWas = $null })
    $s = Q { Invoke-BootCheck }
    $st = Read-JsonFile $StateFile
    Check 'Android 装上之后：删掉免 U 盘安装建的 bcdedit 对象（只一次）' ((Called 'bcdedit /delete {6f0c1a2b-*') -eq 1 -and $null -eq $st['bcd'])
    $null = Q { Invoke-BootCheck }
    Check '下一次开机不再删' ((Called 'bcdedit*') -eq 1)
    Check "系统盘上的 GK3LIVE 去盘符（U19），U 盘上的 GK3LIVE 不碰" ((Called "remove-letter 0:$(Num 'live') L:\") -eq 1 -and (Called 'remove-letter 1:*') -eq 0)
    Check '快速启动又开着 → 关掉，并记下原值' ($script:Reg['HiberbootEnabled'] -eq 0 -and (Read-Companion)['fastStartupWas'] -eq 1)
}
Reset-Fake; $script:Esp = New-FakeEsp -Android -WinEntry
Write-JsonFile $CompanionFile ([ordered]@{ windowsPreset = $true })
$null = Q { Invoke-BootCheck }
Check 'U25 打开：开机写 OneShot = gk3-windows.conf（有自写的 Windows 条目时）' ((GetVarT 'LoaderEntryOneShot') -eq 'gk3-windows.conf')
Reset-Fake; $script:Esp = New-FakeEsp -Android
Write-JsonFile $CompanionFile ([ordered]@{ windowsPreset = $true }); SetVarT 'LoaderEntryOneShot' '*-android-a.conf'
$null = Q { Invoke-BootCheck }
Check 'U25：OneShot 已经是别的（比如刚点了重启到 Android）→ 不覆盖' ((GetVarT 'LoaderEntryOneShot') -eq '*-android-a.conf')
Reset-Fake; $script:Esp = New-FakeEsp -Android
$null = Q { Invoke-BootCheck }
Check 'U25 默认关：开机不写 OneShot' ($null -eq (GetVarT 'LoaderEntryOneShot') -and (Called 'setvar*') -eq 0)

# ── -RepairBoot ──
Write-Host '═══ 伴随工具：-RepairBoot [-Check] ═══'
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 windows
$before = TreeHash $script:Esp
$r = Q { Invoke-RepairBoot $true }
Check '-Check：被换掉时退出码 2、ESP 一个字节不变、不暂停 BitLocker' ($r -eq 2 -and (TreeHash $script:Esp) -eq $before -and (Called 'suspend*') -eq 0)
$r = Q { Invoke-RepairBoot $false }
Check '修：先暂停 BitLocker 1 次重启（那一刻 BOOTAA64 还是 Windows 的）' ($r -eq 0 -and (Called "suspend C: 1 bootaa64=$hWin") -eq 1) (($script:Calls | Where-Object { $_ -like 'suspend*' }) -join '; ')
Check '修：BOOTAA64 = systemd-boot；装机那天的 .before-gaokun3 没被盖掉' ((EH 'EFI/Boot/bootaa64.efi') -eq $hSd -and (EH 'EFI/Boot/bootaa64.efi.before-gaokun3') -eq $hWinOld)
Check '修：不碰 EFI\Microsoft、条目、loader.conf' ((EH 'EFI/Microsoft/Boot/bootmgfw.efi') -eq $hWin -and (Ex "loader/entries/$mid-android-a.conf"))
$r = Q { Invoke-RepairBoot $false }
Check '幂等：再跑一次什么都不做（不再暂停）' ($r -eq 0 -and (Called 'suspend*') -eq 1)
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 windows -NoBackup
$null = Q { Invoke-RepairBoot $false }
Check '没有备份时：把 Windows 换回来的那份留成 .before-gaokun3' ((EH 'EFI/Boot/bootaa64.efi.before-gaokun3') -eq $hWin -and (EH 'EFI/Boot/bootaa64.efi') -eq $hSd)
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 windows; $script:BL = 'Off'
$null = Q { Invoke-RepairBoot $false }
Check 'BitLocker 关着：不暂停，照样修好' ((Called 'suspend*') -eq 0 -and (EH 'EFI/Boot/bootaa64.efi') -eq $hSd)
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 other
$r = Q { Invoke-RepairBoot $false }
Check '是别的东西（另一个 Linux 的引导）：退出码 2、只报告不动' ($r -eq 2 -and (EH 'EFI/Boot/bootaa64.efi') -ne $hSd -and (Called 'suspend*') -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 windows; Remove-Item -Force -LiteralPath (NP (Join-Path $script:Esp 'EFI/systemd/systemd-bootaa64.efi'))
$r = Q { Invoke-RepairBoot $false }
Check '没有 EFI\systemd\systemd-bootaa64.efi：报错退出、什么都不动' ($r -eq 'THREW' -and $script:LastErr -like 'GK3FAIL*' -and (EH 'EFI/Boot/bootaa64.efi') -eq $hWin)
# 家庭版没有 BitLocker 模块：退回 manage-bde
Remove-Item -LiteralPath function:Get-BitLockerVolume, function:Suspend-BitLocker
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 windows
$null = Q { Invoke-RepairBoot $false }
Check '没有 BitLocker 模块：状态按"开着"处理，用 manage-bde -protectors -disable C: -RebootCount 1，且在拷回之前' ((Called 'manage-bde.exe -protectors -disable C: -RebootCount 1') -eq 1 -and (Called "manage-bde-at bootaa64=$hWin") -eq 1 -and (EH 'EFI/Boot/bootaa64.efi') -eq $hSd)
function Get-BitLockerVolume { [CmdletBinding()] param($MountPoint) return [pscustomobject]@{ ProtectionStatus = $script:BL } }
function Suspend-BitLocker { [CmdletBinding()] param($MountPoint, $RebootCount) [void]$script:Calls.Add("suspend $MountPoint $RebootCount bootaa64=$(EH 'EFI/Boot/bootaa64.efi')") }

Write-Host '═══ 伴随工具：-SuspendBitLocker ═══'
Reset-Fake; $script:Esp = New-FakeEsp -Android
$r = Q { Invoke-SuspendBitLockerOnly }
Check '只暂停 2 次重启，别的都不碰（ESP 都不挂）' ($r -eq 0 -and (Called 'suspend C: 2*') -eq 1 -and (Called 'mount-esp') -eq 0 -and (Called 'setvar*') -eq 0)
$script:BL = 'Off'; $r = Q { Invoke-SuspendBitLockerOnly }
Check 'BitLocker 关着：不暂停' ($r -eq 0 -and (Called 'suspend*') -eq 1)

# ── 重启到 Android / 默认系统 ──
Write-Host '═══ 伴随工具：重启到 Android、开机默认系统（写变量的写法照设计稿，Windows 上能不能写【未验证】）═══'
Reset-Fake; $script:Esp = New-FakeEsp -Android
$r = Q { Invoke-RebootToAndroidCli }
Check 'LoaderEntryOneShot = loader.conf 的 default，UTF-16LE + NUL，属性 7，已读回' ($r -eq 0 -and (GetVarT 'LoaderEntryOneShot') -eq '*-android-a.conf' -and [Convert]::ToBase64String($script:Vars['LoaderEntryOneShot'].Data) -eq [Convert]::ToBase64String((ConvertTo-LoaderVarBytes '*-android-a.conf')) -and (Called 'getvar LoaderEntryOneShot') -ge 1)
Check '-NoReboot：不重启' ((Called 'shutdown.exe*') -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android -Default '0123456789abcdef0123456789abcdef-android-b.conf'
$r = Q { Invoke-Trigger 'RebootToAndroid' }
$res = Read-JsonFile (Join-Path $DataDir 'result-RebootToAndroid.json')
Check '开始菜单（不提权）：schtasks /Run 触发固定任务 → 写 OneShot → 写结果 → 3 秒后重启' ($r -eq 0 -and (Called 'schtasks.exe /Run /TN \gaokun3\RebootToAndroid') -eq 1 -and (GetVarT 'LoaderEntryOneShot') -eq "$mid-android-b.conf" -and $res['ok'] -and (Called 'shutdown.exe /r /t 3') -eq 1)
Reset-Fake; $script:Esp = New-FakeEsp -Android; $script:VarFail['set'] = 1
$r = Q { Invoke-Trigger 'RebootToAndroid' }
$res = Read-JsonFile (Join-Path $DataDir 'result-RebootToAndroid.json')
Check '写不进变量：不重启，提示里写明"未验证（D4/D6）"、请在菜单里手选' ($r -eq 1 -and (Called 'shutdown.exe*') -eq 0 -and $res['message'] -match 'D4/D6' -and $res['message'] -match '手选')
Reset-Fake; $script:Esp = New-FakeEsp -Android; $script:RunFails = $true
$r = Q { Invoke-Trigger 'RebootToAndroid' }
Check 'schtasks /Run 被拒（权限设置未验证）：报错并给出以管理员运行的替代命令' ($r -eq 'THREW' -and $script:LastErr -match '-RebootToAndroid')
Reset-Fake; $script:Esp = New-FakeEsp -Android -BootAA64 windows
$r = Q { Get-RebootToAndroidPlan }
Check 'BOOTAA64 被换掉时不写 OneShot（写了也没人读），提示先修复' (-not $r.Ok -and (Called 'setvar*') -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android -Default 'gaokun3-live.conf'
$r = Q { Get-RebootToAndroidPlan }
Check 'loader.conf 的 default 不是 Android 条目：不写' (-not $r.Ok -and (Called 'setvar*') -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android -Gk3boot -WinEntry
$r = Q { Set-DefaultOs 'windows' }
Check '默认 Windows：有 gk3-windows.conf 时写 LoaderEntryDefault = gk3-windows.conf（与 gk3boot.c 的 win_entry_id 同一条规则）' ($r.Ok -and (GetVarT 'LoaderEntryDefault') -eq 'gk3-windows.conf')
Reset-Fake; $script:Esp = New-FakeEsp -Android
$r = Q { Set-DefaultOs 'windows' }
Check '默认 Windows：没有自写条目时写 auto-windows；没有入口时提醒 Android 里的重启也会落到 Windows' ($r.Ok -and (GetVarT 'LoaderEntryDefault') -eq 'auto-windows' -and $r.Message -match 'gk3boot')
$r = Q { Set-DefaultOs 'android' }
Check '默认 Android：删掉 LoaderEntryDefault' ($r.Ok -and $null -eq (GetVarT 'LoaderEntryDefault'))
Reset-Fake; $script:Esp = New-FakeEsp -Android -NoBootmgfw
$r = Q { Set-DefaultOs 'windows' }
Check 'ESP 上没有 bootmgfw.efi：不能设 Windows 为默认' (-not $r.Ok -and (Called 'setvar*') -eq 0)
Reset-Fake; $script:Esp = New-FakeEsp -Android
$null = Q { Invoke-Trigger 'DefaultWindows' }
Check '开始菜单"开机默认进 Windows"走 SYSTEM 任务' ((Called 'schtasks.exe /Run /TN \gaokun3\DefaultWindows') -eq 1 -and (GetVarT 'LoaderEntryDefault') -eq 'auto-windows')

# ── 安装伴随工具 ──
Write-Host '═══ 伴随工具：安装（%ProgramFiles%\gaokun3、计划任务、开始菜单、U18 / U24）═══'
Reset-Fake; $script:Esp = New-FakeEsp -Android
$r = Q { Install-Companion }
Check '装到 InstallDir：ps1 与 cmd 与源一致' ($r -eq 0 -and (FH (Join-Path $InstallDir 'gaokun3-setup.ps1')) -eq (FH $SelfPath) -and (FH (Join-Path $InstallDir 'gaokun3-setup.cmd')) -eq (FH (Join-Path $SrcDir 'gaokun3-setup.cmd')))
Check '建了 5 个计划任务（\gaokun3\…），没建 WindowsShutdown（U25 默认关）还顺手删一次' ((@($script:TaskXml.Keys | Sort-Object) -join ',') -eq '\gaokun3\BootCheck,\gaokun3\DefaultAndroid,\gaokun3\DefaultWindows,\gaokun3\Notify,\gaokun3\RebootToAndroid' -and (Called 'schtasks.exe /Delete /TN \gaokun3\WindowsShutdown /F') -eq 1) (@($script:TaskXml.Keys) -join ',')
$xok = $true; foreach ($k in @($script:TaskXml.Keys)) { try { $null = TX $script:TaskXml[$k] } catch { $xok = $false } }
Check '交给 schtasks 的 XML 文件（UTF-16）读回来都能解析，临时文件删了' ($xok -and @(Get-ChildItem -LiteralPath $DataDir -Filter 'task-*.xml').Count -eq 0)
Check '开始菜单 7 个快捷方式' (@($script:Shortcuts).Count -eq 7)
Check '快速启动关了（U18），原值记下；-Hibernate keep 时不动休眠' ($script:Reg['HiberbootEnabled'] -eq 0 -and (Read-Companion)['fastStartupWas'] -eq 1 -and (Called 'powercfg*') -eq 0)
Check '装完跑了一次开机自检' (Test-Path -LiteralPath $StatusFile)
$Hibernate = 'ask'; $null = Q { Install-Companion }
Check '-Hibernate ask 且 -Yes：按"不关"（征得同意才关，U24）' ((Called 'powercfg*') -eq 0)
$Hibernate = 'off'; $null = Q { Install-Companion }
Check '-Hibernate off：powercfg /hibernate off，原值记下' ((Called 'powercfg.exe /hibernate off') -eq 1 -and (Read-Companion)['hibernateWas'] -eq 1)
Check '重装是幂等的：快速启动原值不被 0 覆盖' ((Read-Companion)['fastStartupWas'] -eq 1)
$Hibernate = 'keep'

Write-Host '═══ 伴随工具：U25 Windows 侧预置（选项，默认关，未验证）═══'
$r = Q { Set-WindowsPresetOption 'on' }
Check '打开：建 WindowsShutdown 任务、现在就写 OneShot = auto-windows' ($script:TaskXml.ContainsKey('\gaokun3\WindowsShutdown') -and (GetVarT 'LoaderEntryOneShot') -eq 'auto-windows' -and (Read-Companion)['windowsPreset'])
$script:ShutType = 'restart'; $null = Q { Invoke-TaskAction 'WindowsShutdown' }
Check 'Windows 重启：OneShot 留着（回 Windows）' ((GetVarT 'LoaderEntryOneShot') -eq 'auto-windows')
$script:ShutType = 'power off'; $null = Q { Invoke-TaskAction 'WindowsShutdown' }
Check 'Windows 关机：比较后删掉 OneShot（冷开机回默认系统）' ($null -eq (GetVarT 'LoaderEntryOneShot'))
SetVarT 'LoaderEntryOneShot' '*-android-a.conf'; $null = Q { Invoke-TaskAction 'WindowsShutdown' }
Check 'OneShot 是别的值（重启到 Android）：不删' ((GetVarT 'LoaderEntryOneShot') -eq '*-android-a.conf')
SetVarT 'LoaderEntryOneShot' 'auto-windows'; $script:ShutType = $null; $null = Q { Invoke-TaskAction 'WindowsShutdown' }
Check '分不清关机还是重启：按关机处理（删）' ($null -eq (GetVarT 'LoaderEntryOneShot'))
SetVarT 'LoaderEntryOneShot' 'auto-windows'
$null = Q { Set-WindowsPresetOption 'off' }
Check '关闭：删任务、删掉 Windows 的 OneShot' ((Called 'schtasks.exe /Delete /TN \gaokun3\WindowsShutdown /F') -ge 2 -and $null -eq (GetVarT 'LoaderEntryOneShot') -and -not (Read-Companion)['windowsPreset'])

Write-Host '═══ 伴随工具：登录时弹窗 ═══'
Reset-Fake
Write-JsonFile $StatusFile ([ordered]@{ issues = @([ordered]@{ id = 'bootaa64-replaced'; key = 'h'; detail = ''; ticks = 1 }, [ordered]@{ id = 'bios-changed'; key = '2.16->2.17'; detail = '2.16 -> 2.17'; ticks = 1 }) })
$script:BoxAnswer = $true
$null = Q { Invoke-Notify }
Check '弹了两条；BOOTAA64 那条点"是"→ 以管理员运行 gaokun3-setup.cmd -RepairBoot' ((Called 'box *') -eq 2 -and (Called "start $InstallDir/gaokun3-setup.cmd -RepairBoot") -eq 1)
$null = Q { Invoke-Notify }
Check '再登录：确认过的 BIOS 提示不再弹，BOOTAA64 那条还弹' ((Called 'box *') -eq 3)

# ── -Uninstall 的回归 ──
Write-Host '═══ 伴随工具：-Uninstall 不碰 EFI\gk3boot、EFI\systemd（回归）═══'
if ($haveFx) {
    Reset-Fake; $null = Load-Disk 'normal'; $script:Esp = New-FakeEsp -Android -Gk3boot -Live -WinEntry
    $script:Reg['HiberbootEnabled'] = 0
    Write-JsonFile $StateFile ([ordered]@{ version = 1; shrinkDrive = 'D'; shrunkBytes = 512MB; bcd = '{6f0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b}'; fallback = $false; loaderConfCreated = $true; fastStartupWas = 1 })
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null; WF (Join-Path $InstallDir 'gaokun3-setup.ps1') 'x'
    $hGk = TreeHash (Join-Path $script:Esp 'EFI/gk3boot'); $hSys = TreeHash (Join-Path $script:Esp 'EFI/systemd'); $hLc = EH 'loader/loader.conf'
    $r = Q { Invoke-Uninstall }
    Check 'Android 装着：EFI\gk3boot 与 EFI\systemd 逐字节不变' ($r -ne 'THREW' -and (TreeHash (Join-Path $script:Esp 'EFI/gk3boot')) -eq $hGk -and (TreeHash (Join-Path $script:Esp 'EFI/systemd')) -eq $hSys) $script:LastErr
    Check 'Android 装着：loader.conf、Android / 入口 / Windows 条目都在（loaderConfCreated 也不删）' ((EH 'loader/loader.conf') -eq $hLc -and (Ex "loader/entries/$mid-android-a.conf") -and (Ex 'loader/entries/gk3boot-android-a+3.conf') -and (Ex 'loader/entries/gk3-windows.conf') -and (Ex "$mid/android/slot_a/Image"))
    Check '只删了安装器自己的：EFI\gaokun3、gaokun3-live.conf；bcdedit 对象' (-not (Ex 'EFI/gaokun3') -and -not (Ex 'loader/entries/gaokun3-live.conf') -and (Called 'bcdedit /delete*') -eq 1)
    Check '快速启动不恢复（U18）、伴随工具保留、不删分区' ($script:Reg['HiberbootEnabled'] -eq 0 -and (Test-Path -LiteralPath $InstallDir) -and (Called 'remove-partition*') -eq 0 -and (Called 'resize*') -eq 0)

    Reset-Fake; $null = Load-Disk 'normal'; $script:Esp = New-FakeEsp -Live
    WF (Join-Path $script:Esp 'loader/loader.conf') "timeout 5`ndefault gaokun3-live.conf`n"
    WF (Join-Path $script:Esp 'EFI/systemd/systemd-bootaa64.efi') 'SOMEONE-ELSES-SYSTEMD-BOOT'
    $script:Reg['HiberbootEnabled'] = 0
    Write-JsonFile $StateFile ([ordered]@{ version = 1; shrinkDrive = 'D'; shrunkBytes = 512MB; bcd = $null; fallback = $false; loaderConfCreated = $true; fastStartupWas = 1 })
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null; WF (Join-Path $InstallDir 'gaokun3-setup.ps1') 'x'
    $hSys = TreeHash (Join-Path $script:Esp 'EFI/systemd')
    $liveNum = Num 'live'
    $r = Q { Invoke-Uninstall }
    Check '没装 Android：别人的 EFI\systemd 不碰；我们建的 loader\ 整个删掉' ($r -ne 'THREW' -and (TreeHash (Join-Path $script:Esp 'EFI/systemd')) -eq $hSys -and -not (Ex 'loader')) $script:LastErr
    Check "没装 Android：删系统盘上的 GK3LIVE（分区 $liveNum），U 盘上同名的不碰；D: 扩回去" ((Called "remove-partition 0 $liveNum") -eq 1 -and (Called 'remove-partition 0 *') -eq 1 -and (Called 'remove-partition 1 *') -eq 0 -and (Called 'resize D *') -eq 1)
    Check '没装 Android：快速启动恢复、伴随工具卸掉、状态文件删掉' ($script:Reg['HiberbootEnabled'] -eq 1 -and -not (Test-Path -LiteralPath $InstallDir) -and -not (Test-Path -LiteralPath $StateFile))
}

# ── -RemoveAndroid ──
Write-Host '═══ 伴随工具：-RemoveAndroid（U20，§4.9.13）═══'
if ($haveFx) {
    Reset-Fake; $null = Load-Disk 'normal'; $script:Esp = New-FakeEsp -Android -Gk3boot -Live -WinEntry
    SetVarT 'LoaderEntryDefault' 'gk3-windows.conf'; SetVarT 'LoaderEntryOneShot' '*-android-a.conf'
    Write-JsonFile $StateFile ([ordered]@{ version = 1; shrinkDrive = 'D'; shrunkBytes = 512MB; bcd = '{bbbbbbbb-0000-4000-8000-000000000002}'; fallback = $false; loaderConfCreated = $false; fastStartupWas = $null })
    Write-JsonFile $CompanionFile ([ordered]@{ fastStartupWas = 1; hibernateWas = 1 })
    $script:Reg['HiberbootEnabled'] = 0; $script:Reg['HibernateEnabled'] = 0
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null; WF (Join-Path $InstallDir 'gaokun3-setup.ps1') 'x'
    $keep = @('EFI/Microsoft/Boot/bootmgfw.efi', 'EFI/Microsoft/Boot/BCD', 'Persisted_Capsules.bin', 'OneKeyLog.txt', 'EFI/UpdateCapsule/cap.bin')
    $hKeep = @($keep | ForEach-Object { EH $_ }) -join ','
    $want = @('live', 'misc', 'metadata', 'boot_a', 'boot_b', 'super', 'userdata' | ForEach-Object { Num $_ } | Sort-Object)
    $dP = @($script:Parts | Where-Object { $_.Role -eq 'D' })[0]; $wP = @($script:Parts | Where-Object { $_.Role -eq 'winpe' })[0]
    $wantSize = $wP.Offset - $dP.Offset
    $r = Q { Invoke-RemoveAndroid }
    $got = @($script:Calls | Where-Object { $_ -like 'remove-partition 0 *' } | ForEach-Object { [int]($_ -split ' ')[2] } | Sort-Object)
    Check '删的正好是 GK3LIVE + Android 的 6 个分区（ESP / MSR / C: / D: / WINPE / U 盘都不碰）' ($r -eq 0 -and ($got -join ',') -eq ($want -join ',') -and (Called 'remove-partition 1 *') -eq 0) "删了 $($got -join ',')，应删 $($want -join ',')；$($script:LastErr)"
    Check '先暂停 BitLocker 1 次重启（那一刻 BOOTAA64 还是 systemd-boot = 还原之前）' ((Called "suspend C: 1 bootaa64=$hSd") -eq 1)
    Check '第 1 步：BOOTAA64 ← 当前的 bootmgfw.efi（不是装机那天的旧备份）' ((EH 'EFI/Boot/bootaa64.efi') -eq $hWin)
    Check '第 2 步：loader\、EFI\systemd、EFI\gk3boot、EFI\gaokun3、<machine-id>\、.before-gaokun3 都删了' (-not (Ex 'loader') -and -not (Ex 'EFI/systemd') -and -not (Ex 'EFI/gk3boot') -and -not (Ex 'EFI/gaokun3') -and -not (Ex $mid) -and -not (Ex 'EFI/Boot/bootaa64.efi.before-gaokun3'))
    Check '绝不碰：EFI\Microsoft、BCD、Persisted_Capsules.bin、OneKeyLog.txt、EFI\UpdateCapsule' ((@($keep | ForEach-Object { EH $_ }) -join ',') -eq $hKeep)
    Check '第 3 步：LoaderEntryDefault / LoaderEntryOneShot 删了（零长度写，本机固件是否照做未验证）' ($script:Vars.Count -eq 0)
    Check "第 4 步：D: 扩到紧挨着的 WINPE 之前（$wantSize 字节）" ((Called "resize D $wantSize") -eq 1)
    Check '第 4 步：快速启动、休眠恢复成原来的开着；bcdedit 对象删掉' ($script:Reg['HiberbootEnabled'] -eq 1 -and $script:Reg['HibernateEnabled'] -eq 1 -and (Called 'bcdedit /delete {bbbbbbbb-*') -eq 1)
    Check '第 5 步：伴随工具、状态文件都卸掉' (-not (Test-Path -LiteralPath $InstallDir) -and -not (Test-Path -LiteralPath $StateFile) -and -not (Test-Path -LiteralPath $CompanionFile) -and (Called 'schtasks.exe /Delete /TN \gaokun3\BootCheck /F') -eq 1)
    $order = @($script:Calls)
    $iS = [array]::IndexOf($order, @($order | Where-Object { $_ -like 'suspend*' })[0]); $iV = [array]::IndexOf($order, @($order | Where-Object { $_ -like 'setvar*' })[0]); $iP = [array]::IndexOf($order, @($order | Where-Object { $_ -like 'remove-partition*' })[0])
    Check '顺序：暂停 BitLocker → 删变量 → 删分区（还原引导在删分区之前）' ($iS -ge 0 -and $iS -lt $iV -and $iV -lt $iP)

    Reset-Fake; $null = Load-Disk 'ntfsdata'; $script:Esp = New-FakeEsp -Android -Live
    SetVarT 'LoaderEntryOneShot' '*-android-a.conf'
    $before = TreeHash $script:Esp
    $r = Q { Invoke-RemoveAndroid }
    Check '名字叫 userdata、里面却是 NTFS：预检拒绝，一个分区不删、ESP 与变量不动、不暂停 BitLocker' ($r -eq 'THREW' -and $script:LastErr -like 'GK3FAIL*' -and (Called 'remove-partition*') -eq 0 -and (TreeHash $script:Esp) -eq $before -and (GetVarT 'LoaderEntryOneShot') -eq '*-android-a.conf' -and (Called 'suspend*') -eq 0)

    Reset-Fake; $null = Load-Disk 'gap'; $script:Esp = New-FakeEsp -Android -Live
    $r = Q { Invoke-RemoveAndroid }
    Check 'D: 后面紧跟 WINPE（不相邻）：分区照删，【不】扩 D:，说明原因' ($r -eq 0 -and (Called 'remove-partition 0 *') -eq 7 -and (Called 'resize*') -eq 0 -and @($script:QOut | Where-Object { $_ -match 'WINPE' }).Count -ge 1) "r=$r $($script:LastErr)"

    Reset-Fake; $null = Load-Disk 'normal'; $script:Esp = New-FakeEsp -Android -Gk3boot -Foreign
    SetVarT 'LoaderEntryDefault' 'arch.conf'; SetVarT 'LoaderEntryOneShot' '*-android-a.conf'
    $r = Q { Invoke-RemoveAndroid }
    Check 'ESP 上还有别的 Linux：只删我们的条目，loader\ 与 EFI\systemd 留着，回落路径不动、不暂停 BitLocker' ($r -eq 0 -and (Ex 'loader/entries/arch.conf') -and -not (Ex "loader/entries/$mid-android-a.conf") -and -not (Ex 'loader/entries/gk3boot-android-a+3.conf') -and (Ex 'EFI/systemd/systemd-bootaa64.efi') -and (EH 'EFI/Boot/bootaa64.efi') -eq $hSd -and (Called 'suspend*') -eq 0) $script:LastErr
    Check '别的 Linux：它的目录不删；loader.conf 换回装机前那份' ((Ex 'ffffffffffffffffffffffffffffffff/6.1/linux') -and (Get-Content -Raw -LiteralPath (NP (Join-Path $script:Esp 'loader/loader.conf'))) -match 'default arch\.conf' -and -not (Ex $mid))
    Check '别的 Linux：只删我们写的变量（OneShot），它的 LoaderEntryDefault=arch.conf 留着' ((GetVarT 'LoaderEntryDefault') -eq 'arch.conf' -and $null -eq (GetVarT 'LoaderEntryOneShot'))

    Reset-Fake; $null = Load-Disk 'normal'; $script:Esp = New-FakeEsp -Android -NoBootmgfw -NoBackup
    $before = TreeHash $script:Esp
    $r = Q { Invoke-RemoveAndroid }
    Check 'ESP 上既没有 bootmgfw.efi 也没有备份：拒绝（删了就没东西能启动），什么都不动' ($r -eq 'THREW' -and (Called 'remove-partition*') -eq 0 -and (TreeHash $script:Esp) -eq $before)
}

Write-Host '═══ 伴随工具：分派 ═══'
$sp = $SelfPath
$SelfPath = $target; $bd = NP (Join-Path $TMP 'bundle'); New-Item -ItemType Directory -Force -Path "$bd/live" | Out-Null
$SelfPath = "$bd/gaokun3-setup.ps1"
Check '不带参数、旁边有 live\（免 U 盘安装包）→ 安装' ((Get-DefaultAction) -eq 'setup')
New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
$SelfPath = Join-Path $InstallDir 'gaokun3-setup.ps1'
Check '不带参数、就在 %ProgramFiles%\gaokun3 里 → 只读体检' ((Get-DefaultAction) -eq 'status')
$SelfPath = $sp
Check '不带参数、只有两个脚本（U 盘上的 gaokun3-windows\）→ 安装伴随工具' ((Get-DefaultAction) -eq 'companion')
$RepairBoot = $true; $RemoveAndroid = $true
$r = Q { Invoke-Main }
Check '一次给两个动作 → 报错' ($r -eq 'THREW' -and $script:LastErr -like 'GK3FAIL*')
$RepairBoot = $false; $RemoveAndroid = $false

Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -LiteralPath $TMP
