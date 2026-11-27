# The search box in the taskbar: its window, where it sits, and the Start button next to it

$bar = New-Object Windows.Forms.Form
$bar.AutoScaleMode = 'None'
$bar.FormBorderStyle = 'None'
$bar.ShowInTaskbar = $false
$bar.StartPosition = 'Manual'
$bar.TopMost = $true
$bar.BackColor = $theme.Bar
$bar.MinimumSize = New-Object Drawing.Size(1, 1)

$pic = New-Object Windows.Forms.PictureBox   # magnifier, or the selected entry's icon
$pic.SizeMode = 'Zoom'
$pic.BackColor = $theme.Bar
$bar.Controls.Add($pic)

$box = New-Object Windows.Forms.TextBox
$box.BorderStyle = 'None'
$box.BackColor = $theme.Bar
$box.ForeColor = [Drawing.Color]::White
$box.Font = New-Object Drawing.Font('Segoe UI', 10)
$bar.Controls.Add($box)

$script:magnifier = $null
$script:lay = $null

function Test-Typing { $box.Focused -and $box.Text }

# Magnifier drawn once per size (bar icon when nothing is typed)
function New-Magnifier([int]$s) {
    $b = New-Object Drawing.Bitmap($s, $s)
    $gr = [Drawing.Graphics]::FromImage($b); $gr.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(200, 200, 200), [single]([Math]::Max(1.5, $s / 11)))
    $d = $s * 0.58; $o = $s * 0.08
    $gr.DrawEllipse($pen, [single]$o, [single]$o, [single]$d, [single]$d)
    $gr.DrawLine($pen, [single]($o + $d * 0.85), [single]($o + $d * 0.85), [single]($s * 0.92), [single]($s * 0.92))
    $gr.Dispose(); $b
}

# ---- Position ----

# The taskbar's rectangle and edge (top or bottom), from the screen minus the working area (stable).
# The Shell_TrayWnd window itself sometimes grows (hidden icons menu, animations): only used as a last resort.
function Get-TaskbarBounds {
    $scr = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $wa  = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $atTop = $false
    if ($wa.Top -gt $scr.Top) { $atTop = $true; $hgt = $wa.Top - $scr.Top }
    elseif ($wa.Bottom -lt $scr.Bottom) { $hgt = $scr.Bottom - $wa.Bottom }
    else {
        # auto-hidden taskbar: look at where Shell_TrayWnd is
        $t = [LauncherNative]::Taskbar()
        $atTop = (-not $t.IsEmpty) -and ($t.Top -le $scr.Top + 2) -and ($t.Bottom -lt $scr.Bottom - 2)
        $hgt = if (-not $t.IsEmpty) { $t.Height } else { 0 }
    }
    if ($hgt -lt 20 -or $hgt -gt 120 * $scale) { $hgt = px 40 }   # not ready yet
    $y = if ($atTop) { $scr.Top } else { $scr.Bottom - $hgt }
    @{ Rect = New-Object Drawing.Rectangle($scr.Left, $y, $scr.Width, $hgt); AtTop = $atTop }
}

# Where the bar goes in the taskbar: left (in place of the Start button) or right (just left of the clock)
function Get-BarBounds([Drawing.Rectangle]$tb) {
    $w = px $Width
    $h = [int]([Math]::Min($tb.Height * 0.66, 36 * $scale))
    if ($script:side -eq 'Left') {
        $x = $tb.Left + (px 6)
    } else {
        $right = [LauncherNative]::TrayLeft()
        if ($right -le $tb.Left + $w -or $right -gt $tb.Right) { $right = $tb.Right - (px $RightMargin) }   # tray not found
        $x = $right - $w - (px 8)
    }
    New-Object Drawing.Rectangle($x, ($tb.Top + [int](($tb.Height - $h) / 2)), $w, $h)
}

# Rounded corners, icon on the left, text on the right
function Set-BarShape([int]$w, [int]$h) {
    $bar.Region = New-Object Drawing.Region (New-RoundedPath $w $h (px 8))
    $is = [int]($h * 0.58)
    $pic.Bounds = New-Object Drawing.Rectangle((px 8), [int](($h - $is) / 2), $is, $is)
    $script:magnifier = New-Magnifier $is
    if (-not $box.Text) { $pic.Image = $script:magnifier }
    $box.Left = $pic.Right + (px 6)
    $box.Width = $w - $box.Left - (px 8)
    $box.Top = [int](($h - $box.Height) / 2)
}

# Places the bar in the taskbar. Called continuously: re-aligns if the taskbar wasn't ready at startup,
# or if the screen changes. Handles the taskbar at the top OR the bottom.
function Update-Layout {
    $tb = Get-TaskbarBounds
    $script:tbAtTop = $tb.AtTop; $script:tbTop = $tb.Rect.Top; $script:tbBottom = $tb.Rect.Bottom; $script:tbLeft = $tb.Rect.Left
    $want = Get-BarBounds $tb.Rect
    $key = "$($want.X),$($want.Y),$($want.Width),$($want.Height),$($tb.Rect.Top)"
    if ($key -eq $script:lay) {
        # Windows sometimes moves the window by itself (into the working area): put it back
        if (-not $bar.Bounds.Equals($want)) { $bar.Bounds = $want; Write-Log 'Repositioned (Windows had moved it)' }
        return
    }
    $script:lay = $key
    $script:barX = $want.X
    $bar.Bounds = $want
    Set-BarShape $want.Width $want.Height
}

# ---- Side (right-click menu), saved in %APPDATA%\Launcher\settings.json ----
#   Right: next to the clock (default)   Left: in place of the Start button
# Top / bottom always follows the taskbar itself.
$settingsFile = Join-Path $env:APPDATA 'Launcher\settings.json'
$script:side = 'Right'
try { if ((Get-Content $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json).Side -eq 'Left') { $script:side = 'Left' } } catch {}

function Set-Side([string]$s) {
    $script:side = $s
    try { @{ Side = $s } | ConvertTo-Json | Set-Content -Encoding UTF8 $settingsFile } catch {}
    Write-Log "Position: $s"
    Update-Layout; Update-StartButton
}

# ---- Start button ----
# Hidden when the bar takes its place (left) or when $HideStartButton is on.
# Then the pinned / open apps slide left: into the button's spot, or just after the bar.
$script:startHidden = $false
function Update-StartButton {
    if ($script:side -eq 'Left') {
        [LauncherNative]::StartButton($false, $bar.Right - $script:tbLeft + (px 6)); $script:startHidden = $true
    } elseif ($HideStartButton) {
        [LauncherNative]::StartButton($false, 0); $script:startHidden = $true
    } elseif ($script:startHidden) {
        [LauncherNative]::StartButton($true, 0); $script:startHidden = $false
    }
}

# ---- Staying in place ----
# Every 500 ms: above the taskbar, in the right place, hidden while an app is full screen.
$script:hidden = $false
$script:prevWin = [IntPtr]::Zero   # last window used outside the bar (Esc gives the keyboard back to it)

function Show-BarAgain { if ($script:hidden) { [LauncherNative]::ShowNoActivate($bar.Handle); $script:hidden = $false } }

function Update-Bar {
    $f = [LauncherNative]::OtherForeground(); if ($f -ne [IntPtr]::Zero) { $script:prevWin = $f }
    # Full screen (movie, game...): the taskbar goes away, so does the search bar
    if ([LauncherNative]::FullscreenApp()) {
        if (-not $script:hidden) { $pop.Hide(); [LauncherNative]::Hide($bar.Handle); $script:hidden = $true }
        return
    }
    Show-BarAgain
    Update-Layout
    [LauncherNative]::AttachToTaskbar($bar.Handle)   # redone if Explorer restarted
    [LauncherNative]::KeepOnTop($bar.Handle)
    Update-StartButton   # redone if Explorer brought the button back or re-laid out the taskbar
}

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$timer.Add_Tick({ Update-Bar })

$bar.Add_Load({ Update-Layout; [LauncherNative]::AttachToTaskbar($bar.Handle); Start-IconPreload })
