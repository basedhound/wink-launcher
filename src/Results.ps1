# The suggestion list under (or above) the bar: the window, the rows, the thin scrollbar

# Normal searches show 10 results at most; game lists ("steam ", "gog ") keep up to 100 and scroll
$visibleRows = 10
$maxGames    = 100
$gamePrefix  = '^\s*(' + (($gameGroups.Values | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s'
$popW        = px 360
$arrow       = [string][char]0x2192
$script:results = @()
$script:aliasMode = $null   # "ch=chrome" typed: the alias being created

$pop = New-Object LauncherPopup
$pop.AutoScaleMode = 'None'
$pop.FormBorderStyle = 'None'
$pop.ShowInTaskbar = $false
$pop.StartPosition = 'Manual'
$pop.BackColor = $theme.Popup
$pop.Padding = New-Object Windows.Forms.Padding(px 6)

# The list's own scrollbar is pushed out of view by a clipping panel (always there, so rows keep the same width);
# a thin rounded thumb is drawn over the list instead.
$clip = New-Object Windows.Forms.Panel
$clip.Dock = 'Fill'
$list = New-Object Windows.Forms.ListBox
$list.ScrollAlwaysVisible = $true
$list.Font = New-Object Drawing.Font('Segoe UI', 11)
$list.BackColor = $theme.Popup
$list.ForeColor = [Drawing.Color]::Gainsboro
$list.BorderStyle = 'None'
$list.IntegralHeight = $false
$list.DrawMode = 'OwnerDrawFixed'
$list.ItemHeight = px 34
$clip.Controls.Add($list)
$pop.Controls.Add($clip)

$thumb = New-Object Windows.Forms.Panel
$thumb.Width = px 4
$thumb.BackColor = $theme.Thumb
$thumb.Visible = $false
$clip.Controls.Add($thumb); $thumb.BringToFront()

$clip.Add_Resize({
    $list.Bounds = New-Object Drawing.Rectangle(0, 0, ($clip.Width + [Windows.Forms.SystemInformation]::VerticalScrollBarWidth), $clip.Height)
    Update-Thumb
})

# ---- Rows ----

$tagFont  = New-Object Drawing.Font('Segoe UI', 8)
$brBg     = New-Object Drawing.SolidBrush($theme.Popup)
$brSel    = New-Object Drawing.SolidBrush($theme.Selection)
$rowFlags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix'
$tagFlags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Right, SingleLine, NoPrefix'

# Kind tag on the right for anything that isn't a plain app ("Control Panel", "Settings", "Steam"...).
# Returns the x where the name must stop.
function Write-KindTag($gr, $a, [Drawing.Rectangle]$row, [int]$right, [bool]$sel) {
    if (-not $a.Kind -or $a.Kind -eq 'App') { return $right }
    $kw = [Windows.Forms.TextRenderer]::MeasureText($a.Kind, $tagFont).Width
    $r = New-Object Drawing.Rectangle(($right - $kw), $row.Y, $kw, $row.Height)
    [Windows.Forms.TextRenderer]::DrawText($gr, $a.Kind, $tagFont, $r, $(if ($sel) { [Drawing.Color]::LightGray } else { [Drawing.Color]::Gray }), $tagFlags)
    $right - $kw - (px 8)
}

# One row: icon, name, kind tag
function Write-ResultRow($e) {
    $gr = $e.Graphics; $row = $e.Bounds; $a = $script:results[$e.Index]
    $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $gr.FillRectangle($(if ($sel) { $brSel } else { $brBg }), $row)
    $isz = px 24; $pad = px 8
    $ico = Get-AppIcon $a
    if ($ico) {
        $gr.InterpolationMode = 'HighQualityBicubic'
        $gr.DrawImage($ico, $row.X + $pad, $row.Y + [int](($row.Height - $isz) / 2), $isz, $isz)
    }
    $tx = $row.X + $pad * 2 + $isz
    $right = Write-KindTag $gr $a $row ($row.Right - $pad) $sel
    $rect = New-Object Drawing.Rectangle($tx, $row.Y, ($right - $tx), $row.Height)
    $col = if ($sel) { [Drawing.Color]::White } else { [Drawing.Color]::Gainsboro }
    [Windows.Forms.TextRenderer]::DrawText($gr, [string]$list.Items[$e.Index], $list.Font, $rect, $col, $rowFlags)
}

$list.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $script:results.Count) { return }
    Write-ResultRow $e
    Update-Thumb   # rows get redrawn whenever the list scrolls (wheel, arrows)
})

# ---- Thin scrollbar ----

function Get-VisibleRowCount { [int][Math]::Floor($list.ClientSize.Height / $list.ItemHeight) }

function Update-Thumb {
    $n = $list.Items.Count; $vis = [Math]::Max(1, (Get-VisibleRowCount))
    if ($n -le $vis) { if ($thumb.Visible) { $thumb.Visible = $false }; return }
    $trackH = $clip.Height - (px 4)
    $h = [Math]::Max((px 24), [int]($trackH * $vis / $n))
    $y = (px 2) + [int](($trackH - $h) * [Math]::Min(1.0, $list.TopIndex / ($n - $vis)))
    $b = New-Object Drawing.Rectangle(($clip.Width - $thumb.Width - (px 2)), $y, $thumb.Width, $h)
    if ($thumb.Bounds -ne $b) {
        $thumb.Bounds = $b
        $path = New-Object Drawing.Drawing2D.GraphicsPath   # rounded ends
        $d = $thumb.Width
        $path.AddArc(0, 0, $d, $d, 180, 180); $path.AddArc(0, $h - $d, $d, $d, 0, 180); $path.CloseFigure()
        $thumb.Region = New-Object Drawing.Region $path
    }
    if (-not $thumb.Visible) { $thumb.Visible = $true }
}

function Set-ListTop([int]$top) {
    $max = [Math]::Max(0, $list.Items.Count - (Get-VisibleRowCount))
    $list.TopIndex = [Math]::Max(0, [Math]::Min($max, $top))
    Update-Thumb
}

# Dragging the thumb scrolls the list
$thumb.Add_MouseEnter({ $thumb.BackColor = $theme.ThumbHover })
$thumb.Add_MouseLeave({ if (-not $script:thumbDrag) { $thumb.BackColor = $theme.Thumb } })
$thumb.Add_MouseDown({ $script:thumbDrag = @{ Y = [Windows.Forms.Control]::MousePosition.Y; Top = $list.TopIndex } })
$thumb.Add_MouseUp({
    $script:thumbDrag = $null
    if (-not $thumb.ClientRectangle.Contains($thumb.PointToClient([Windows.Forms.Control]::MousePosition))) { $thumb.BackColor = $theme.Thumb }
})
$thumb.Add_MouseMove({
    if (-not $script:thumbDrag) { return }
    $span = $clip.Height - (px 4) - $thumb.Height
    $rows = $list.Items.Count - (Get-VisibleRowCount)
    if ($span -le 0 -or $rows -le 0) { return }
    $dy = [Windows.Forms.Control]::MousePosition.Y - $script:thumbDrag.Y
    Set-ListTop ($script:thumbDrag.Top + [int][Math]::Round($dy * $rows / $span))
})

# ---- Showing results ----

function Update-BarIcon {
    $i = $list.SelectedIndex
    $img = if ($box.Text -and $i -ge 0 -and $i -lt $script:results.Count) { Get-AppIcon $script:results[$i] } else { $null }
    $pic.Image = if ($img) { $img } else { $script:magnifier }
}
$list.Add_SelectedIndexChanged({ Update-BarIcon })

# Searches the typed text ("ch=chrome": alias creation mode, the search is on what follows "=")
function Find-Results {
    if ($box.Text -match '^\s*([^=]+?)\s*=\s*(.*)$') { $script:aliasMode = $Matches[1]; $q = $Matches[2] }
    else { $script:aliasMode = $null; $q = $box.Text }
    $script:results = @(Find-Apps $q $(if ($q -match $gamePrefix) { $maxGames } else { $visibleRows }))
}

function Set-ListItems {
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($a in $script:results) {
        if ($script:aliasMode) { [void]$list.Items.Add("Alias  $($script:aliasMode)  $arrow  $($a.Name)") }
        else { [void]$list.Items.Add((Get-AppLabel $a)) }
    }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $list.EndUpdate()
}

# At most $visibleRows rows (beyond that the list scrolls); below the bar when the taskbar is at the top, above otherwise
function Get-PopupBounds {
    $ph = [Math]::Min($list.Items.Count, $visibleRows) * $list.ItemHeight + (px 12) + 4
    $px = [Math]::Min($script:barX, [Windows.Forms.Screen]::PrimaryScreen.Bounds.Right - $popW - 4)
    $py = if ($script:tbAtTop) { $script:tbBottom + (px 6) } else { $script:tbTop - $ph - (px 6) }
    New-Object Drawing.Rectangle($px, $py, $popW, $ph)
}

function Show-Results {
    Find-Results
    Set-ListItems
    Update-BarIcon
    if (-not $list.Items.Count) { $pop.Hide(); return }
    $pop.Bounds = Get-PopupBounds
    $list.TopIndex = 0; Update-Thumb
    if (-not $pop.Visible) { $pop.Show() }
    [LauncherNative]::AttachToTaskbar($pop.Handle)
    [LauncherNative]::KeepOnTop($pop.Handle)
    if (-not $box.Focused) { $box.Focus() }
}

function Reset-Bar { $box.Text = ''; $pop.Hide(); $pic.Image = $script:magnifier }

# Short temporary message shown in the empty bar
$flashTimer = New-Object Windows.Forms.Timer
$flashTimer.Interval = 2500
$flashTimer.Add_Tick({ $flashTimer.Stop(); [LauncherNative]::Placeholder($box.Handle, '') })
function Show-Flash([string]$msg) {
    [LauncherNative]::Placeholder($box.Handle, $msg)
    $flashTimer.Stop(); $flashTimer.Start()
}
