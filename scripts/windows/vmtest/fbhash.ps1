& mountvol.exe Y: /S | Out-Null
foreach ($f in 'Y:\EFI\Boot\bootaa64.efi', 'Y:\EFI\Boot\bootaa64.efi.before-gaokun3', 'Y:\EFI\gaokun3\systemd-bootaa64.efi') {
    if (Test-Path $f) { Write-Host ("{0} {1}" -f (Get-FileHash -Algorithm SHA256 $f).Hash.Substring(0,16), $f) } else { Write-Host "(none) $f" }
}
& mountvol.exe Y: /D | Out-Null
