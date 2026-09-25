$v = Get-Volume -FileSystemLabel Data
Write-Host ("keep-me: " + (Get-Content "$($v.DriveLetter):\keep-me.txt"))
& mountvol.exe Y: /S | Out-Null
Get-ChildItem -Force Y:\ -Recurse -Directory | Where-Object { $_.FullName -match 'loader|gaokun3' } | ForEach-Object { Write-Host ("dir: " + $_.FullName + " items=" + @(Get-ChildItem -Force $_.FullName).Count) }
& mountvol.exe Y: /D | Out-Null
