# Installs Wink: a scheduled task that starts the bar at logon
# and restarts it by itself (checked every 5 minutes) if it was closed by accident.
# No admin rights needed.
$dir = $PSScriptRoot
$ps  = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$dir\LauncherBar.ps1`""

# The task doesn't run the bar itself: it asks Explorer to start it (Shell.Application.ShellExecute).
# A process started straight by Task Scheduler is treated as a background process: clicking the bar
# wouldn't give it the focus, so clicking a suggestion did nothing. Started by Explorer, it behaves like
# any app. ShellExecute show = 0: hidden from the start. conhost --headless: no black window flashing.
$start = "(New-Object -ComObject Shell.Application).ShellExecute('$ps', '$($arg -replace "'", "''")', '$($dir -replace "'", "''")', 'open', 0)"
$enc   = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($start))
$action   = New-ScheduledTaskAction -Execute "$env:WINDIR\System32\conhost.exe" -Argument "--headless `"$ps`" -NoProfile -EncodedCommand $enc" -WorkingDirectory $dir
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 5)).Repetition
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'LauncherBar' -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null

# Start now (and cancel a previous "Quit")
Remove-Item (Join-Path $env:APPDATA 'Launcher\stopped') -ErrorAction SilentlyContinue
Start-ScheduledTask -TaskName 'LauncherBar'
Write-Host 'Wink installed: the bar shows up in the taskbar (click it or tap the Windows key).'
