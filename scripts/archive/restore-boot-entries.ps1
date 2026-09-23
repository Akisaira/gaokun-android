<#
    从 Windows 恢复 Ego U 盘的 systemd-boot 启动项

    背景：为了排除启动项误选，之前把三个可用的 7.1.0-rc3 条目全部停用，
    只留了新编的 7.2.0-rc2。新内核起不来，于是没有退路了。
    这个脚本把可用条目放回去，并把起不来的新内核条目挪走。

    用法：以【管理员】身份打开 PowerShell，然后
        powershell -ExecutionPolicy Bypass -File restore-boot-entries.ps1

    只动 U 盘 ESP 上的 .conf 文件，不碰内核镜像、不碰 rootfs、不碰内置硬盘。
#>

$ErrorActionPreference = 'Stop'

function Fail($m) { Write-Host "错误: $m" -ForegroundColor Red; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "必须以管理员身份运行"
}

# ---- 1. 找到 U 盘上的 ESP ----
$usb = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.PartitionStyle -eq 'GPT' }
if (-not $usb) { Fail "没检测到 GPT 分区的 USB 磁盘，U 盘插好了吗？" }
if ($usb -is [array]) { Fail "检测到多个 USB 磁盘，请只插目标 U 盘" }

Write-Host "USB 磁盘: $($usb.FriendlyName)  $([math]::Round($usb.Size/1GB,1)) GB  (disk $($usb.Number))"

$esp = Get-Partition -DiskNumber $usb.Number |
       Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }
if (-not $esp) { Fail "该 U 盘上没有 EFI 系统分区" }

# ---- 2. 确保有盘符 ----
$letter = $esp.DriveLetter
if (-not $letter) {
    Write-Host "ESP 没有盘符，正在分配..."
    Add-PartitionAccessPath -DiskNumber $usb.Number -PartitionNumber $esp.PartitionNumber -AssignDriveLetter
    Start-Sleep -Seconds 2
    $letter = (Get-Partition -DiskNumber $usb.Number -PartitionNumber $esp.PartitionNumber).DriveLetter
}
if (-not $letter) { Fail "无法为 ESP 分配盘符" }
$ESPRoot = "${letter}:"
Write-Host "ESP 盘符: $ESPRoot"

# ---- 3. 校验这确实是我们要找的盘 ----
$entries  = Join-Path $ESPRoot 'loader\entries'
$disabled = Join-Path $entries 'disabled'
$loaderConf = Join-Path $ESPRoot 'loader\loader.conf'

if (-not (Test-Path $loaderConf)) { Fail "$loaderConf 不存在 —— 这不是那块 Ego 启动盘" }
if (-not (Test-Path $disabled))   { Fail "$disabled 不存在 —— 可能已经恢复过了" }

Write-Host ""
Write-Host "=== 恢复前 ==="
Write-Host "可选条目:"; Get-ChildItem $entries -Filter *.conf -File -EA SilentlyContinue |
    ForEach-Object { Write-Host "    $($_.Name)" }
Write-Host "已停用:"; Get-ChildItem $disabled -Filter *.conf -File |
    ForEach-Object { Write-Host "    $($_.Name)" }

# ---- 4. 把可用条目放回去 ----
Write-Host ""
Write-Host "=== 恢复 7.1.0-rc3 条目 ==="
Get-ChildItem $disabled -Filter *.conf -File | ForEach-Object {
    Move-Item $_.FullName (Join-Path $entries $_.Name) -Force
    Write-Host "    放回 $($_.Name)"
}

# ---- 5. 把起不来的新内核条目挪走 ----
Write-Host ""
Write-Host "=== 停用起不来的 7.2.0-rc2 条目 ==="
Get-ChildItem $entries -Filter '*7.2.0-rc2*.conf' -File -EA SilentlyContinue | ForEach-Object {
    Move-Item $_.FullName (Join-Path $disabled $_.Name) -Force
    Write-Host "    停用 $($_.Name)  (内核镜像仍在，随时可以再启用)"
}

# ---- 6. 默认项指回已知可用的内核 ----
$std = '8a29534fa802480d9fbb71aa18c01d7b-7.1.0-rc3-gaokun3+.conf'
if (Test-Path (Join-Path $entries $std)) {
    (Get-Content $loaderConf) -replace '^default .*', "default $std" |
        Set-Content $loaderConf -Encoding ascii
    Write-Host ""
    Write-Host "默认项已指回: $std"
} else {
    Write-Host "警告: 找不到 ${std}，请手动确认 loader.conf" -ForegroundColor Yellow
}

# ---- 7. 结果 ----
Write-Host ""
Write-Host "=== 恢复后 ==="
Write-Host "可选条目:"
Get-ChildItem $entries -Filter *.conf -File | ForEach-Object { Write-Host "    $($_.Name)" }
Write-Host ""
Write-Host "loader.conf:"
Get-Content $loaderConf | ForEach-Object { Write-Host "    $_" }

Write-Host ""
Write-Host "完成。安全弹出 U 盘，插回 Ego 开机即可。" -ForegroundColor Green
Write-Host "起来后菜单会有三个 7.1.0-rc3 条目，选哪个都能进系统。"
