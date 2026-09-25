param([string]$Log = '\\Mac\gk3out\uninstall.log')
& C:\gk3\gaokun3-setup.ps1 -Uninstall -Yes -NoReboot *>&1 | Out-File -Encoding utf8 $Log
"EXIT=$LASTEXITCODE" | Out-File -Append -Encoding utf8 $Log
