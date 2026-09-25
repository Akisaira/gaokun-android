@echo off
rem gaokun3 USB-free install launcher: runs gaokun3-setup.ps1 (same folder) as Administrator.
rem Arguments are passed through, e.g.:  gaokun3-setup.cmd -AndroidGiB 100
rem (ASCII only on purpose: cmd reads this file in the OEM code page.)
powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -NoExit -File \"%~dp0gaokun3-setup.ps1\" %*'"
