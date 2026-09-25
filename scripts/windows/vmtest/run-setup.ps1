# Run the real installer script like a user would (bundle unzipped to C:\gk3), log as UTF-8.
param([string]$Log = '\\Mac\gk3out\setup.log', [string]$ShrinkDrive = 'D', [switch]$UseFallbackPath)
Remove-Item -Recurse -Force C:\gk3 -ErrorAction SilentlyContinue
Copy-Item -Recurse -Path \\Mac\gk3bundle -Destination C:\gk3
$p = @{ SkipModelCheck = $true; Yes = $true; NoReboot = $true; AndroidGiB = 24; ShrinkDrive = $ShrinkDrive; UseFallbackPath = [bool]$UseFallbackPath }
& C:\gk3\gaokun3-setup.ps1 @p *>&1 | Out-File -Encoding utf8 $Log
"EXIT=$LASTEXITCODE" | Out-File -Append -Encoding utf8 $Log
