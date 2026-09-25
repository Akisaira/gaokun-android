# Snapshot of disk / boot state for before-after comparison (ASCII only).
param([string]$Out)
$ErrorActionPreference = 'Continue'
$r = @()
$r += '== partitions (disk 0)'
$r += (Get-Partition -DiskNumber 0 | Sort-Object Offset | Format-Table -AutoSize PartitionNumber, DriveLetter, @{n='OffsetMiB';e={[math]::Round($_.Offset/1MB)}}, @{n='SizeMiB';e={[math]::Round($_.Size/1MB)}}, GptType, Guid | Out-String -Width 250)
$r += '== volumes'
$r += (Get-Volume | Where-Object { $_.DriveType -eq 'Fixed' } | Format-Table -AutoSize DriveLetter, FileSystemLabel, FileSystem, @{n='SizeMiB';e={[math]::Round($_.Size/1MB)}}, @{n='FreeMiB';e={[math]::Round($_.SizeRemaining/1MB)}} | Out-String -Width 250)
$r += '== bcdedit /enum firmware'
$r += (& bcdedit.exe /enum firmware | Out-String)
$r += '== ESP'
& mountvol.exe Y: /S | Out-Null
if (Test-Path 'Y:\') {
    $r += (Get-ChildItem -Recurse -Force Y:\ -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer } | ForEach-Object { '{0,12} {1}' -f $_.Length, $_.FullName } | Out-String -Width 250)
    $r += ('ESP free MiB: ' + [math]::Floor(([IO.DriveInfo]::new('Y:\')).AvailableFreeSpace / 1MB))
    & mountvol.exe Y: /D | Out-Null
} else { $r += 'cannot mount ESP' }
$sf = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'gaokun3\windows-setup.json'
$r += '== state file'
if (Test-Path $sf) { $r += (Get-Content $sf -Raw) } else { $r += '(none)' }
$r | Set-Content -Path $Out -Encoding UTF8
Write-Host "snapshot -> $Out"
