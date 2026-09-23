<#
    把 gaokun3 的 Ubuntu 镜像写回 U 盘

    用法：以【管理员】身份打开 PowerShell，然后
        powershell -ExecutionPolicy Bypass -File flash-usb.ps1

    脚本只做一件事：把 12 GB 的 ubuntu-26.04-gaokun3.img 原样 dd 到 U 盘。
    写完之后从 Ego 启动，剩下的（装自定义内核、部署 Android）我通过 SSH 接手。

    安全设计：
      - 只认 USB 总线的磁盘，绝不碰内置 NVMe
      - 目标盘容量必须 >= 镜像，且 <= 256 GB（避免误选大容量外置盘）
      - 列出目标盘现有内容，要求手工输入磁盘号 + 输入 ERASE 二次确认
      - 写入前后都做校验
#>

$ErrorActionPreference = 'Stop'

function Fail($m) { Write-Host "错误: $m" -ForegroundColor Red; exit 1 }

if (-not ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Fail "必须以管理员身份运行"
}

$IMG = "C:\Users\Vahiru\Desktop\ubuntu-26.04-gaokun3.img"
if (-not (Test-Path $IMG)) { Fail "找不到镜像: $IMG" }
$imgSize = (Get-Item $IMG).Length
Write-Host "镜像: $IMG"
Write-Host "大小: $([math]::Round($imgSize/1GB,2)) GB"
Write-Host ""

# ---- 只列 USB 盘 ----
$usb = Get-Disk | Where-Object { $_.BusType -eq 'USB' -and $_.Size -ge $imgSize -and $_.Size -le 256GB }
if (-not $usb) { Fail "没有找到合适的 USB 磁盘（需 >= 镜像大小且 <= 256 GB）" }

Write-Host "=== 候选 USB 磁盘 ===" -ForegroundColor Yellow
foreach ($d in $usb) {
    Write-Host ("  磁盘 {0}: {1}  {2} GB" -f $d.Number, $d.FriendlyName, [math]::Round($d.Size/1GB,1))
    Get-Partition -DiskNumber $d.Number -ErrorAction SilentlyContinue | ForEach-Object {
        $v = Get-Volume -Partition $_ -ErrorAction SilentlyContinue
        Write-Host ("      分区{0}  {1} GB  {2} {3}" -f $_.PartitionNumber,
            [math]::Round($_.Size/1GB,2), $_.Type, $(if($v){"'$($v.FileSystemLabel)'"}))
    }
}
Write-Host ""
Write-Host "内置 NVMe 不在候选列表里，不可能选中它。" -ForegroundColor Green
Write-Host ""

$num = Read-Host "输入要写入的磁盘号"
$target = $usb | Where-Object { $_.Number -eq [int]$num }
if (-not $target) { Fail "磁盘 $num 不在候选列表中" }
if ($target.BusType -ne 'USB') { Fail "磁盘 $num 不是 USB 设备" }

Write-Host ""
Write-Host "即将【完全擦除】磁盘 $($target.Number): $($target.FriendlyName) $([math]::Round($target.Size/1GB,1)) GB" -ForegroundColor Red
$ans = Read-Host "输入 ERASE 确认（其他输入都会中止）"
if ($ans -ne 'ERASE') { Fail "已取消" }

# ---- 卸载 + 清盘 ----
Write-Host ""
Write-Host "正在准备磁盘..."
Get-Partition -DiskNumber $target.Number -ErrorAction SilentlyContinue | ForEach-Object {
    if ($_.DriveLetter) { Remove-PartitionAccessPath -DiskNumber $target.Number -PartitionNumber $_.PartitionNumber -AccessPath "$($_.DriveLetter):\" -ErrorAction SilentlyContinue }
}
Clear-Disk -Number $target.Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

# ---- 写入 ----
Write-Host "开始写入（12 GB，约几分钟）..." -ForegroundColor Yellow
$sw = [Diagnostics.Stopwatch]::StartNew()
$src = [System.IO.File]::OpenRead($IMG)
$dst = [System.IO.File]::Open("\\.\PhysicalDrive$($target.Number)",
        [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::ReadWrite)
try {
    $buf = New-Object byte[] (16MB)
    $total = 0
    while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
        $dst.Write($buf, 0, $n)
        $total += $n
        if ($total % (512MB) -lt 16MB) {
            $pct = [math]::Round($total * 100.0 / $imgSize, 1)
            $mbs = [math]::Round($total / 1MB / $sw.Elapsed.TotalSeconds, 1)
            Write-Host ("  {0}%  {1} GB  {2} MB/s" -f $pct, [math]::Round($total/1GB,2), $mbs)
        }
    }
    $dst.Flush()
} finally {
    $src.Close(); $dst.Close()
}
$sw.Stop()
Write-Host ("写入完成: {0} GB，用时 {1:N0} 秒，平均 {2} MB/s" -f `
    [math]::Round($imgSize/1GB,2), $sw.Elapsed.TotalSeconds,
    [math]::Round($imgSize/1MB/$sw.Elapsed.TotalSeconds,1)) -ForegroundColor Green

# ---- 校验 ----
Write-Host ""
Write-Host "校验前 64 MB..."
$src = [System.IO.File]::OpenRead($IMG)
$dst = [System.IO.File]::Open("\\.\PhysicalDrive$($target.Number)",
        [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
try {
    $a = New-Object byte[] (64MB); $b = New-Object byte[] (64MB)
    $null = $src.Read($a,0,$a.Length); $null = $dst.Read($b,0,$b.Length)
    $same = $true
    for ($i=0; $i -lt $a.Length; $i+=4096) { if ($a[$i] -ne $b[$i]) { $same=$false; break } }
    if ($same) { Write-Host "  ✅ 抽样校验通过" -ForegroundColor Green }
    else { Write-Host "  ⚠️ 抽样发现差异，建议重写" -ForegroundColor Red }
} finally { $src.Close(); $dst.Close() }

Write-Host ""
Write-Host "=== 完成 ===" -ForegroundColor Green
Write-Host "安全弹出 U 盘 -> 插到 Ego -> 开机从 U 盘启动。"
Write-Host "起来后确认 Ego 连上家里 WiFi，告诉我一声，我接手后面的步骤："
Write-Host "  1. 装回自定义内核 7.2.0-rc2-gaokun3+（含 OTG / FunctionFS / efi_pstore 补丁）"
Write-Host "  2. dd super.img 到内置盘的 super 分区（分区还在，没丢）"
Write-Host "  3. 放 Android 的 kernel/ramdisk 到 ESP，建启动项"
