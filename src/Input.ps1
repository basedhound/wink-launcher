# What the keyboard, the mouse and the menus do in the bar and the suggestion list

# ---- Choosing ----

function Get-SelectedEntry {
    $i = $list.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:results.Count) { $script:results[$i] }
}

# Enter or click: create the alias being typed ("ch=chrome"), open the alias manager (":alias"), or launch
function Start-Choice {
    $app = Get-SelectedEntry
    if ($box.Text.Trim() -eq ':alias') { Reset-Bar; Show-AliasManager; return }
    if ($script:aliasMode) { Save-TypedAlias $app; return }
    if (Invoke-Launch $app $box.Text) { Reset-Bar }
}

function Save-TypedAlias($app) {
    $alias = $script:aliasMode
    $target = if ($app) { $app.Name } else { ($box.Text -split '=', 2)[1] }
    if (-not $target.Trim()) { return }
    Add-Alias $alias $target
    Reset-Bar
    Show-Flash ([char]0x2713 + " $alias $arrow $target")
}

# Right-click a suggestion > "Give this app an alias": puts "=AppName" in the bar, cursor at the start,
# so you just type the alias and press Enter
function Start-AliasForSelection {
    $app = Get-SelectedEntry
    if (-not $app) { return }
    $pop.Hide()
    [LauncherNative]::Front($bar.Handle)
    $box.Focus()
    $box.Text = "=$($app.Name)"
    $box.SelectionStart = 0
    $box.SelectionLength = 0
}

# ---- Keyboard ----

# Ctrl+Backspace: delete the previous word, like everywhere else
# (by default a WinForms text box would insert a strange box character instead)
function Remove-PreviousWord {
    if ($box.SelectionLength) { $box.SelectedText = ''; return }
    $p = $box.SelectionStart
    $before = $box.Text.Substring(0, $p) -replace '\S*\s*$', ''
    $box.Text = $before + $box.Text.Substring($p)
    $box.SelectionStart = $before.Length
}

function Move-Selection([int]$step) {
    if ($step -gt 0 -and -not $pop.Visible) { Show-Results; return }   # Down with the list closed: show it
    $i = $list.SelectedIndex + $step
    if ($i -ge 0 -and $i -lt $list.Items.Count) { $list.SelectedIndex = $i }
}

# Esc: clear and leave the bar, back to the window used before
function Exit-Bar {
    Reset-Bar
    if ([LauncherNative]::Alive($script:prevWin)) { [LauncherNative]::Front($script:prevWin) }
}

$box.Add_KeyDown({
    param($s, $e)
    $ctrl = $e.Control -and -not $e.Alt
    $key = [int]$e.KeyCode
    $handled = $true
    if ($ctrl -and $key -eq 32) { Reset-Bar }                 # Ctrl+Space: clear, stay in the bar
    elseif ($ctrl -and $key -eq 8) { Remove-PreviousWord }    # Ctrl+Backspace
    elseif ($key -eq 40) { Move-Selection 1 }                 # Down
    elseif ($key -eq 38) { Move-Selection -1 }                # Up
    elseif ($key -eq 13) { Start-Choice }                     # Enter
    elseif ($key -eq 27) { Exit-Bar }                         # Esc
    else { $handled = $false }
    if ($handled) { $e.SuppressKeyPress = $true }
})

$box.Add_GotFocus({
    $n = $script:apps.Count
    Update-AppsIfStale
    if ($script:apps.Count -ne $n) { Start-IconPreload }
    if ($box.Text) { Show-Results }
})
$box.Add_TextChanged({ if ($box.Text) { Show-Results } else { $pop.Hide(); $pic.Image = $script:magnifier } })

# The focus stays in the box: the wheel over the box scrolls the suggestions too
$box.Add_MouseWheel({ if ($pop.Visible) { Set-ListTop ($list.TopIndex - [Math]::Sign($_.Delta) * 3) } })

# ---- Mouse ----

# Launch on left button release over a suggestion (MouseUp: MouseClick isn't raised reliably on this no-activate popup)
$list.Add_MouseUp({
    if ($_.Button -ne 'Left') { return }
    $i = $list.IndexFromPoint($_.Location)
    if ($i -ge 0) { $list.SelectedIndex = $i; Start-Choice }
})
# Right button: select the row under the mouse (its menu then acts on it)
$list.Add_MouseDown({ if ($_.Button -eq 'Right') { $i = $list.IndexFromPoint($_.Location); if ($i -ge 0) { $list.SelectedIndex = $i } } })

$bar.Add_MouseDown({ [LauncherNative]::Front($bar.Handle); $box.Focus() })
$pic.Add_MouseDown({ [LauncherNative]::Front($bar.Handle); $box.Focus() })
$box.Add_MouseDown({ [LauncherNative]::Front($bar.Handle) })

# Clicking elsewhere clears the bar and hides the suggestions
# (but not a click on the suggestion list itself: that click must still reach the list and launch the app)
$bar.Add_Deactivate({
    if ($pop.Visible -and $pop.Bounds.Contains([Windows.Forms.Control]::MousePosition)) { return }
    Reset-Bar
})

# ---- Windows key ----

# Tapped alone: opens the bar with its text selected (Ctrl+Esc still opens the Start menu)
function Open-Bar {
    $f = [LauncherNative]::OtherForeground(); if ($f -ne [IntPtr]::Zero) { $script:prevWin = $f }
    Show-BarAgain
    [LauncherNative]::Front($bar.Handle)
    $bar.Activate(); $box.Focus(); $box.SelectAll()
}
$hk = New-Object LauncherNative
$hk.add_HotKey({ Open-Bar })

# ---- Menus (dark, roomier items) ----

$darkMenu = New-Object DarkMenuRenderer
function Set-DarkMenu($m) {
    $m.Renderer = $darkMenu; $m.Font = New-Object Drawing.Font('Segoe UI', 10)
    $m.ShowImageMargin = $false; $m.ShowCheckMargin = $false
    foreach ($i in $m.Items) {
        if ($i -is [Windows.Forms.ToolStripMenuItem]) { $i.Padding = New-Object Windows.Forms.Padding((px 6), (px 4), (px 12), (px 4)) }
    }
}

# Right-click a suggestion
$itemMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$itemMenu.Items.Add('Give this app an alias', $null, { Start-AliasForSelection })
Set-DarkMenu $itemMenu
$list.ContextMenuStrip = $itemMenu

# Right-click the bar: aliases, shortcuts folder, move to the other side, quit
function Switch-Side { Set-Side $(if ($script:side -eq 'Left') { 'Right' } else { 'Left' }) }
function Stop-Bar { Write-Log 'Quit (menu)'; Set-Content $stopFlag '' -ErrorAction SilentlyContinue; $bar.Close() }

$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Aliases', $null, { Reset-Bar; Show-AliasManager })
[void]$menu.Items.Add('Shortcuts', $null, { Reset-Bar; Start-Process explorer.exe "`"$shortcutDir`"" })   # new files show up in the search by themselves
$miMove = $menu.Items.Add('Move to left', $null, { Switch-Side })   # names the other side (top / bottom follows the taskbar)
$menu.Add_Opening({ $miMove.Text = if ($script:side -eq 'Left') { 'Move to right' } else { 'Move to left' } })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Quit', $null, { Stop-Bar })
Set-DarkMenu $menu
foreach ($c in $bar, $box, $pic) { $c.ContextMenuStrip = $menu }
