# 在 PowerShell 7 容器里测 gaokun3-setup.ps1（bash scripts/windows/test-setup.sh 起容器跑这个）。
# 测得了：语法、编码、有没有 5.1 不认的语法、以及全部纯逻辑（bcdedit 输出解析、PSK 推导、WiFi 配置转换、
# 压缩大小计算）。测不了：Resize-Partition / New-Partition / mountvol / bcdedit 本身 —— 那些只在 Windows 上有。
# -Out <文件>：把测试里生成的 wpa_supplicant 网络块写出去，test-setup.sh 再拿真 wpa_supplicant 解析它。
param([string]$Out = '')
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $PSCommandPath
$target = Join-Path $here 'gaokun3-setup.ps1'
$script:pass = 0; $script:fail = 0
function Check([string]$What, [bool]$Ok, [string]$Detail = '') {
    if ($Ok) { $script:pass++; Write-Host "  ✓ $What" } else { $script:fail++; Write-Host "  ✗ $What  $Detail" }
}

Write-Host '═══ 文件本身 ═══'
$tokens = $null; $errs = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errs)
Check '语法：解析零错误' ($errs.Count -eq 0) ($errs | Out-String)
$bytes = [IO.File]::ReadAllBytes($target)
Check 'UTF-8 带 BOM（Windows PowerShell 5.1 没有 BOM 就按系统代码页读，中文全乱）' ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
$lf = 0; $crlf = 0
for ($i = 0; $i -lt $bytes.Length; $i++) { if ($bytes[$i] -eq 10) { if ($i -gt 0 -and $bytes[$i - 1] -eq 13) { $crlf++ } else { $lf++ } } }
Check "行尾全是 CRLF（$crlf 行）" ($lf -eq 0) "$lf 行是裸 LF"
# 5.1 不认、7 才有的语法：?: 三元、?? / ??=、&& / ||、?. / ?[]
$bad = $ast.FindAll({
    param($n)
    ($n -is [System.Management.Automation.Language.TernaryExpressionAst]) -or
    ($n -is [System.Management.Automation.Language.PipelineChainAst]) -or
    ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'QuestionQuestion') -or
    ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'QuestionQuestionEquals') -or
    ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.NullConditional) -or
    ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.NullConditional)
}, $true)
Check '没有 PowerShell 7 才有的语法' ($bad.Count -eq 0) (($bad | ForEach-Object { "第 $($_.Extent.StartLineNumber) 行：$($_.Extent.Text)" }) -join '; ')

# 只加载函数，不跑主流程（脚本末尾按 InvocationName 判断）
. $target

Write-Host '═══ bcdedit 输出里认 GUID（输出是本地化的）═══'
$g = '{6f0c1a2b-3c4d-4e5f-8a9b-0c1d2e3f4a5b}'
Check '英文' ((Get-BcdGuid "The entry was successfully copied to $g.") -eq $g)
Check '中文' ((Get-BcdGuid "已将该项成功复制到 $g。") -eq $g)
Check '没有 GUID → $null' ($null -eq (Get-BcdGuid '拒绝访问。'))

Write-Host '═══ WPA2 的 PSK 推导（期望值由 Python hashlib.pbkdf2_hmac 算出；前两组是 IEEE 802.11i 的测试向量）═══'
$vec = @(
    @('password', 'IEEE', 'f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e'),
    @('ThisIsAPassword', 'ThisIsASSID', '0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af'),
    @('12345678', 'SkipM4', '1cd8c9126075fc5f21f403cc7ba314d298847a47f259824a675d21aba6b23a96'),
    @('中文密码测试123', '宿舍网-5G', '2e15ca22b4d3bca755a5f2018d7773d35a934298abea3b1c1424787eee2c4290')
)
foreach ($v in $vec) {
    $got = Get-WpaPsk $v[0] ([Text.Encoding]::UTF8.GetBytes($v[1]))
    Check "PSK(`"$($v[0])`", `"$($v[1])`")（SSID $([Text.Encoding]::UTF8.GetByteCount($v[1])) 字节）" ($got -eq $v[2]) "得到 $got"
}

Write-Host '═══ netsh 导出的 WLAN 配置 → wpa_supplicant ═══'
function P([string]$Name, [string]$Hex, [string]$Auth, [string]$Enc, [string]$Key, [string]$OneX = 'false', [string]$KeyType = 'passPhrase') {
    $sk = ''
    if ($Key) { $sk = "<sharedKey><keyType>$KeyType</keyType><protected>false</protected><keyMaterial>$([Security.SecurityElement]::Escape($Key))</keyMaterial></sharedKey>" }
    $h = ''; if ($Hex) { $h = "<hex>$Hex</hex>" }
    return [xml]@"
<?xml version="1.0"?>
<WLANProfile xmlns="http://www.microsoft.com/networking/WLAN/profile/v1">
  <name>$([Security.SecurityElement]::Escape($Name))</name>
  <SSIDConfig><SSID>$h<name>$([Security.SecurityElement]::Escape($Name))</name></SSID></SSIDConfig>
  <connectionType>ESS</connectionType><connectionMode>auto</connectionMode>
  <MSM><security><authEncryption><authentication>$Auth</authentication><encryption>$Enc</encryption><useOneX>$OneX</useOneX></authEncryption>$sk</security></MSM>
</WLANProfile>
"@
}
$zhHex = ConvertTo-HexString ([Text.Encoding]::UTF8.GetBytes('宿舍网-5G'))
$cases = @(
    @{ n = 'WPA2 密码 → 写推导出的 PSK，不写明文'; p = (P 'SkipM4' '536B69704D34' 'WPA2PSK' 'AES' '12345678');
       want = "network={`n    ssid=536b69704d34`n    psk=1cd8c9126075fc5f21f403cc7ba314d298847a47f259824a675d21aba6b23a96`n    key_mgmt=WPA-PSK`n}" },
    @{ n = '中文 SSID（hex 节点）+ 中文密码'; p = (P '宿舍网-5G' $zhHex.ToUpper() 'WPA2PSK' 'AES' '中文密码测试123');
       want = "network={`n    ssid=$zhHex`n    psk=2e15ca22b4d3bca755a5f2018d7773d35a934298abea3b1c1424787eee2c4290`n    key_mgmt=WPA-PSK`n}" },
    @{ n = '已经是 64 位十六进制的 PSK → 原样用（转小写）'; p = (P 'HexNet' '' 'WPA2PSK' 'AES' ('AB' * 32) 'false' 'networkKey');
       want = "network={`n    ssid=4865784e6574`n    psk=$('ab' * 32)`n    key_mgmt=WPA-PSK`n}" },
    @{ n = '开放网络'; p = (P 'Cafe' '' 'open' 'none' '');
       want = "network={`n    ssid=43616665`n    key_mgmt=NONE`n}" },
    @{ n = 'WPA3 SAE → 只能写明文 sae_password'; p = (P 'W3' '' 'WPA3SAE' 'AES' 'sae-pass-123');
       want = "network={`n    ssid=5733`n    sae_password=`"sae-pass-123`"`n    key_mgmt=SAE`n    ieee80211w=2`n}" },
    @{ n = 'WPA3 密码里有双引号 → 跳过（写不进引号串）'; p = (P 'W3q' '' 'WPA3SAE' 'AES' 'a"bcdefgh'); want = $null },
    @{ n = '企业网（802.1X）→ 跳过'; p = (P 'eduroam' '' 'WPA2' 'AES' '' 'true'); want = $null },
    @{ n = 'WEP（authentication 也写作 open）→ 跳过'; p = (P 'OldWep' '' 'open' 'WEP' '1234567890' 'false' 'networkKey'); want = $null },
    @{ n = 'WPA2 密码短于 8 位（坏配置）→ 跳过'; p = (P 'Short' '' 'WPA2PSK' 'AES' '1234567'); want = $null }
)
$blocks = @()
foreach ($c in $cases) {
    $got = ConvertTo-WpaNetwork $c.p
    Check $c.n ($got -eq $c.want) "`n得到：$got`n期望：$($c.want)"
    if ($got) { $blocks += $got }
}
if ($Out) { [IO.File]::WriteAllText($Out, (($blocks -join "`n`n") + "`n"), (New-Object Text.UTF8Encoding($false))); Write-Host "  → 生成的 $($blocks.Count) 个网络块写到 $Out（test-setup.sh 拿真 wpa_supplicant 解析）" }

Write-Host '═══ 压缩大小 ═══'
$G = [long]1GB; $M = [long]1MB
$t = Get-ShrinkTarget (336 * $G) (2 * $G) (64 * $G + 4096 * $M) (10 * $G)
Check '336 GiB 缩出 64 GiB + 4 GiB → 268 GiB' ($t -eq 268 * $G) "得到 $t"
Check '结果按 1 MiB 对齐' ((Get-ShrinkTarget (100 * $G + 12345) 0 (10 * $G) 0) % $M -eq 0)
Check '会压到"最小值 + 给 Windows 留的余量"以下 → $null' ($null -eq (Get-ShrinkTarget (80 * $G) (20 * $G) (64 * $G) (10 * $G)))
Check '刚好卡在余量线上 → 放行' ((Get-ShrinkTarget (100 * $G) (20 * $G) (70 * $G) (10 * $G)) -eq 30 * $G)

Write-Host '═══ loader.conf ═══'
$lc = Format-LoaderConf
Check 'default 指向安装器、有超时（Windows 在菜单里）、编辑器关' ($lc -match '(?m)^default gaokun3-live\.conf$' -and $lc -match '(?m)^timeout [1-9]' -and $lc -match '(?m)^editor no$')

Write-Host ''
Write-Host "═══ 通过 $script:pass · 失败 $script:fail ═══"
if ($script:fail -gt 0) { exit 1 }
