# Search bar that sits inside the Windows taskbar.
# Click it (or tap the Windows key), type, press Enter to launch.

# ---- Settings (in "logical" pixels, at 100 % scaling) ----
$Width       = 110     # width of the search bar
$RightMargin = 290     # only used if the clock / tray area can't be found
$WindowsKey  = $true   # tap the Windows key alone to open the bar (instead of the Start menu)
$HideStartButton = $true   # hide the taskbar's Start button (Ctrl+Esc still opens the Start menu)
# ----------------------------------------------------------

# Single instance
$mutex = New-Object Threading.Mutex($false, 'Local\LauncherBar')
if (-not $mutex.WaitOne(0)) { exit }

# If the bar was quit on purpose, the auto-restart task doesn't reopen it until the next reboot
$stopFlag = Join-Path $env:APPDATA 'Launcher\stopped'
if (Test-Path $stopFlag) {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ((Get-Item $stopFlag).LastWriteTime -gt $boot) { exit }
    Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue
}

$src = Join-Path $PSScriptRoot 'src'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Path (Join-Path $src 'Native.cs') -ReferencedAssemblies System.Windows.Forms, System.Drawing, System
[void][LauncherNative]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

# Log (start, stop, launches, errors) in %APPDATA%\Launcher\bar.log
$logFile = Join-Path $env:APPDATA 'Launcher\bar.log'
New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null
function Write-Log([string]$m) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 200KB) { Remove-Item $logFile -Force }
        Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) -Encoding UTF8
    } catch {}
}
Write-Log "Start (PID $PID)"
# An error in the bar must never close it: log it and carry on
[Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log "Error: $($e.Exception.Message)" })

. (Join-Path $src 'Theme.ps1')         # colours, sizes, screen scaling
. (Join-Path $src 'Catalog.ps1')       # what can be found and launched (loads the app list)
. (Join-Path $src 'Icons.ps1')         # icons, cached and preloaded
. (Join-Path $src 'Bar.ps1')           # the search box and its place in the taskbar
. (Join-Path $src 'Results.ps1')       # the suggestion list
. (Join-Path $src 'Input.ps1')         # keyboard, mouse, menus, Windows key
. (Join-Path $src 'AliasWindow.ps1')   # alias manager
. (Join-Path $src 'Reload.ps1')        # keeps the app list up to date

$timer.Start()          # stay above the taskbar, in the right place
$gogTimer.Start()
$refreshTimer.Start()
if ($WindowsKey) { $hk.StartWinKey() }

try { [Windows.Forms.Application]::Run($bar) }
catch { Write-Log "Stopped on error: $($_.Exception.Message)" }
if ($script:startHidden) { [LauncherNative]::StartButton($true, 0) }   # give the Start button back when the bar closes
Write-Log 'Stop'
$mutex.ReleaseMutex()
