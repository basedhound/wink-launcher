@echo off
rem Reopens the launcher bar, even after "Quit".
rem If the LauncherBar scheduled task is missing or points to another folder (the Launcher
rem folder was moved), it is re-registered from here via Install.ps1, which also starts the bar.
powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Command ^
  "$d = '%~dp0'.TrimEnd('\');" ^
  "Remove-Item (Join-Path $env:APPDATA 'Launcher\stopped') -ErrorAction SilentlyContinue;" ^
  "$t = Get-ScheduledTask -TaskName LauncherBar -ErrorAction SilentlyContinue;" ^
  "if ($t -and $t.Actions[0].WorkingDirectory -eq $d) { Start-ScheduledTask -TaskName LauncherBar }" ^
  "else { & (Join-Path $d 'Install.ps1') | Out-Null }"
