# Recreate the test "Data" volume at 60 GiB (the 40 GiB one was too small for 24 GiB + 4 GiB + 10 GiB margin).
$ErrorActionPreference = 'Stop'
$v = Get-Volume -FileSystemLabel Data -ErrorAction SilentlyContinue
if ($v) { $p = $v | Get-Partition; Remove-Partition -DiskNumber $p.DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false }
$c = Get-Partition -DriveLetter C
Resize-Partition -DriveLetter C -Size ($c.Size - 20GB)
$c = Get-Partition -DriveLetter C
$off = [long]([math]::Ceiling(($c.Offset + $c.Size) / 1MB)) * 1MB
$d = New-Partition -DiskNumber $c.DiskNumber -Offset $off -Size 60GB -AssignDriveLetter
Format-Volume -Partition $d -FileSystem NTFS -NewFileSystemLabel Data -Confirm:$false | Out-Null
$v = Get-Volume -FileSystemLabel Data
Set-Content -Path "$($v.DriveLetter):\keep-me.txt" -Value 'data that must survive'
Write-Host "DATA=$($v.DriveLetter) $([math]::Round($v.Size/1GB)) GiB"
