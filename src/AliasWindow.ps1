# Alias manager window (dark): add an alias, edit one with a double-click, delete one with the cross.
# Changes are saved as soon as they're made. The bar stays usable while it's open (try a new alias right away).
#
# The window runs inside Show-AliasManager (ShowDialog): its event handlers, and the Alias* helpers they call,
# see the window's controls ($f, $grid, $aliasBox...) as variables of that function.

$aliasFont  = New-Object Drawing.Font('Segoe UI', 10)
$aliasBlank = New-Object Drawing.Bitmap(1, 1)   # empty icon cell
$aliasCross = [string][char]0x2715

# ---- Building blocks ----

# Rounded corners on a control, redone when it's resized
$roundCorners = {
    $r = px 6
    if ($this.Width -lt $r * 2 -or $this.Height -lt $r * 2) { return }
    $this.Region = New-Object Drawing.Region (New-RoundedPath $this.Width $this.Height $r)
}

function New-AliasButton([string]$text, $back, $hover) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $back; $b.FlatAppearance.MouseOverBackColor = $hover; $b.FlatAppearance.MouseDownBackColor = $hover
    $b.ForeColor = [Drawing.Color]::White; $b.Cursor = 'Hand'; $b.Add_Resize($roundCorners)
    $b
}

# Text field: a borderless text box inside a rounded panel, vertically centered
function New-AliasField {
    $p = New-Object Windows.Forms.Panel
    $p.Dock = 'Fill'; $p.BackColor = $theme.Bar; $p.Margin = New-Object Windows.Forms.Padding(0, 0, (px 8), 0); $p.Cursor = 'IBeam'
    $t = New-Object Windows.Forms.TextBox
    $t.BorderStyle = 'None'; $t.BackColor = $theme.Bar; $t.ForeColor = $theme.Text; $t.Font = $aliasFont
    $p.Controls.Add($t)
    $p.Add_Resize({ $tb = $this.Controls[0]; $tb.SetBounds((px 10), [int](($this.Height - $tb.Height) / 2), $this.Width - (px 20), $tb.Height) })
    $p.Add_Resize($roundCorners)
    $p.Add_Click({ $this.Controls[0].Focus() })
    $p
}

function New-AliasHeader {
    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = px 82; $head.Padding = New-Object Windows.Forms.Padding((px 20), (px 16), (px 20), 0)
    $sub = New-Object Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = px 24; $sub.ForeColor = $theme.Muted; $sub.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $sub.Text = 'Type an alias in the bar to launch its target: an app, a folder, a URL or a command.'
    $title = New-Object Windows.Forms.Label
    $title.Dock = 'Top'; $title.Height = px 34; $title.Text = 'Aliases'; $title.ForeColor = [Drawing.Color]::White
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
    $head.Controls.AddRange(@($sub, $title))
    $head
}

# Names offered while typing a target: everything the bar finds (apps, your shortcuts, Settings pages,
# Control Panel items, games, actions), not the targets of other aliases (paths, URLs, commands)
function New-AliasNameList {
    $names = New-Object Windows.Forms.AutoCompleteStringCollection
    $names.AddRange([string[]]@($script:apps | Where-Object { $_.Kind -ne 'Command' } | ForEach-Object { $_.Name } | Sort-Object -Unique))
    , $names
}

function Set-AutoComplete($textBox, $names) {
    $textBox.AutoCompleteMode = 'SuggestAppend'; $textBox.AutoCompleteSource = 'CustomSource'; $textBox.AutoCompleteCustomSource = $names
}

# New alias row: [alias] [target] [Add]
function New-AliasInputRow($names) {
    $row = New-Object Windows.Forms.TableLayoutPanel
    $row.Dock = 'Top'; $row.Height = px 58; $row.Padding = New-Object Windows.Forms.Padding((px 20), (px 8), (px 20), (px 10))
    $row.ColumnCount = 3; $row.RowCount = 1
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 30)))
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 70)))
    [void]$row.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (px 90))))
    [void]$row.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $aliasField = New-AliasField; $targetField = New-AliasField
    Set-AutoComplete $targetField.Controls[0] $names
    $addBtn = New-AliasButton 'Add' $theme.Selection $theme.AccentHover
    $addBtn.Dock = 'Fill'; $addBtn.Margin = New-Object Windows.Forms.Padding(0)
    $row.Controls.Add($aliasField, 0, 0); $row.Controls.Add($targetField, 1, 0); $row.Controls.Add($addBtn, 2, 0)
    @{ Panel = $row; Alias = $aliasField.Controls[0]; Target = $targetField.Controls[0]; Add = $addBtn }
}

function New-AliasGrid {
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.BackgroundColor = $theme.Popup; $grid.BorderStyle = 'None'; $grid.GridColor = $theme.Line
    $grid.CellBorderStyle = 'SingleHorizontal'; $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'
    $grid.EnableHeadersVisualStyles = $false; $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'; $grid.ColumnHeadersHeight = px 32
    $grid.RowTemplate.Height = px 42; $grid.EditMode = 'EditProgrammatically'
    $cells = $grid.DefaultCellStyle
    $cells.BackColor = $theme.Popup; $cells.ForeColor = $theme.Text
    $cells.SelectionBackColor = $theme.RowSelect; $cells.SelectionForeColor = [Drawing.Color]::White
    $cells.Padding = New-Object Windows.Forms.Padding((px 4), 0, 0, 0)
    $heads = $grid.ColumnHeadersDefaultCellStyle
    $heads.BackColor = $theme.Popup; $heads.ForeColor = $theme.Muted; $heads.SelectionBackColor = $theme.Popup
    $heads.Font = New-Object Drawing.Font('Segoe UI', 9); $heads.Padding = New-Object Windows.Forms.Padding((px 4), 0, 0, 0)
    $grid.Columns.AddRange([Windows.Forms.DataGridViewColumn[]](New-AliasColumns))
    foreach ($c in $grid.Columns) { $c.SortMode = 'NotSortable'; $c.Resizable = 'False' }
    $grid
}

# Columns: icon, alias, target, delete cross
function New-AliasColumns {
    $icon = New-Object Windows.Forms.DataGridViewImageColumn
    $icon.HeaderText = ''; $icon.AutoSizeMode = 'None'; $icon.Width = px 46; $icon.ImageLayout = 'Zoom'; $icon.ReadOnly = $true
    $icon.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding((px 14), (px 11), (px 4), (px 11)); $icon.DefaultCellStyle.NullValue = $aliasBlank
    $alias = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $alias.HeaderText = 'ALIAS'; $alias.FillWeight = 30
    $alias.DefaultCellStyle.ForeColor = $theme.Alias; $alias.DefaultCellStyle.SelectionForeColor = $theme.Alias
    $alias.DefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $target = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $target.HeaderText = 'TARGET'; $target.FillWeight = 70
    $del = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $del.HeaderText = ''; $del.AutoSizeMode = 'None'; $del.Width = px 46; $del.ReadOnly = $true
    $del.DefaultCellStyle.Alignment = 'MiddleCenter'; $del.DefaultCellStyle.ForeColor = $theme.Muted; $del.DefaultCellStyle.SelectionForeColor = $theme.Muted
    @($icon, $alias, $target, $del)
}

function New-AliasEmptyLabel {
    $empty = New-Object Windows.Forms.Label
    $empty.Dock = 'Fill'; $empty.TextAlign = 'MiddleCenter'; $empty.ForeColor = $theme.Muted; $empty.BackColor = $theme.Popup
    $empty.Text = "No aliases yet.`nAdd one above, for example  ch  " + [char]0x2192 + "  Google Chrome."
    $empty
}

# Footer: "Open alias.txt" on the left, Done on the right
function New-AliasFooter {
    $foot = New-Object Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = px 60; $foot.Padding = New-Object Windows.Forms.Padding((px 20), (px 12), (px 20), (px 14))
    $done = New-AliasButton 'Done' $theme.Bar $theme.BarHover
    $done.Dock = 'Right'; $done.Width = px 96
    $open = New-Object Windows.Forms.LinkLabel
    $open.Dock = 'Left'; $open.AutoSize = $false; $open.Width = px 200; $open.TextAlign = 'MiddleLeft'; $open.Text = 'Open alias.txt'
    $open.LinkColor = $theme.Muted; $open.ActiveLinkColor = [Drawing.Color]::White; $open.LinkBehavior = 'HoverUnderline'
    $foot.Controls.AddRange(@($done, $open))
    @{ Panel = $foot; Done = $done; Open = $open }
}

function New-AliasForm {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Aliases'; $f.ShowIcon = $false; $f.KeyPreview = $true   # a normal window: other windows can go over it
    $f.StartPosition = 'CenterScreen'; $f.AutoScaleMode = 'None'
    $f.Size = New-Object Drawing.Size((px 640), (px 540)); $f.MinimumSize = New-Object Drawing.Size((px 460), (px 360))
    $f.BackColor = $theme.Popup; $f.ForeColor = $theme.Text; $f.Font = $aliasFont
    $f
}

# ---- Behaviour (called from the window's event handlers) ----

function Get-AliasIcon([string]$alias) {
    $k = ConvertTo-Key $alias
    $a = $script:apps | Where-Object { $_.Aliases -contains $k } | Select-Object -First 1
    $img = if ($a) { Get-AppIcon $a }
    if ($img) { $img } else { $aliasBlank }
}

function Import-AliasGrid {
    $grid.Rows.Clear()
    foreach ($a in Read-Aliases) { [void]$grid.Rows.Add((Get-AliasIcon $a.Alias), $a.Alias, $a.Target, $aliasCross) }
    $grid.ClearSelection(); $empty.Visible = $grid.Rows.Count -eq 0
    $script:aliasMgrStamp = (Get-Item $aliasFile).LastWriteTime
}

function Save-AliasGrid {
    $out = @($aliasHeader)
    foreach ($r in $grid.Rows) {
        $a = "$($r.Cells[1].Value)".Trim(); $c = "$($r.Cells[2].Value)".Trim()
        if ($a -and $c) { $out += "$a = $c" }
    }
    $out | Set-Content -Encoding UTF8 $aliasFile
    Update-Aliases
    foreach ($r in $grid.Rows) { $r.Cells[0].Value = Get-AliasIcon "$($r.Cells[1].Value)" }
    $empty.Visible = $grid.Rows.Count -eq 0
    $script:aliasMgrStamp = (Get-Item $aliasFile).LastWriteTime
}

# The alias typed in the input row: added (replacing an alias with the same name), then selected
function Add-AliasRow {
    $a = $aliasBox.Text.Trim(); $t = $targetBox.Text.Trim()
    if (-not $a) { $aliasBox.Focus(); return }
    if (-not $t) { $targetBox.Focus(); return }
    $k = ConvertTo-Key $a
    foreach ($r in @($grid.Rows)) { if ((ConvertTo-Key "$($r.Cells[1].Value)") -eq $k) { $grid.Rows.Remove($r) } }
    $i = $grid.Rows.Add($aliasBlank, $a, $t, $aliasCross)
    Save-AliasGrid
    $aliasBox.Text = ''; $targetBox.Text = ''; $aliasBox.Focus()
    $grid.ClearSelection(); $grid.Rows[$i].Selected = $true; $grid.FirstDisplayedScrollingRowIndex = $i
}

# Edit finished: an emptied alias or target removes the row (after the edit is over), otherwise it's saved
function Complete-AliasEdit([int]$row) {
    $r = $grid.Rows[$row]
    if (-not "$($r.Cells[1].Value)".Trim() -or -not "$($r.Cells[2].Value)".Trim()) {
        # A row can't be removed while its edit is ending: done right after. The row is kept in a script
        # variable, because this function's own variables are gone by then.
        $script:aliasRowToRemove = $r
        $grid.BeginInvoke([Action]{ $grid.Rows.Remove($script:aliasRowToRemove); $script:aliasRowToRemove = $null; Save-AliasGrid }) | Out-Null
    } else { Save-AliasGrid }
}

# Cross column: red on hover, deletes the row on click
function Set-CrossHover([int]$row, [bool]$on) {
    $c = $grid.Rows[$row].Cells[3]
    $col = if ($on) { $theme.Delete } else { $theme.Muted }
    $c.Style.ForeColor = $col; $c.Style.SelectionForeColor = $col
    $grid.Cursor = if ($on) { 'Hand' } else { 'Default' }
}

# Esc: clears the field being typed in (and its suggestion list) first, closes the window when it's empty
function Undo-AliasField {
    $tb = $f.ActiveControl -as [Windows.Forms.TextBox]
    if ($tb -and $tb.Text) { $tb.Text = '' } else { $f.Close() }
}

function Register-AliasEvents {
    $inputRow.Add.Add_Click({ Add-AliasRow })
    $enter = { param($sender, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; Add-AliasRow } }
    $aliasBox.Add_KeyDown($enter); $targetBox.Add_KeyDown($enter)

    # Double-click (or F2) a cell to edit it; saved when the edit ends. Delete key: removes the row.
    $grid.Add_CellDoubleClick({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -in 1, 2) { $grid.BeginEdit($true) } })
    $grid.Add_KeyDown({ param($sender, $e)
        if ($e.KeyCode -eq 'F2' -and $grid.CurrentCell -and $grid.CurrentCell.ColumnIndex -in 1, 2) { $grid.BeginEdit($true); $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Delete' -and $grid.CurrentRow) { $grid.Rows.Remove($grid.CurrentRow); Save-AliasGrid; $e.Handled = $true }
    })
    $grid.Add_CellEndEdit({ param($sender, $e) Complete-AliasEdit $e.RowIndex })
    $grid.Add_EditingControlShowing({ param($sender, $e)
        $tb = $e.Control -as [Windows.Forms.TextBox]; if (-not $tb) { return }
        $tb.BackColor = $theme.Bar; $tb.ForeColor = $theme.Text
        if ($grid.CurrentCell.ColumnIndex -eq 2) { Set-AutoComplete $tb $names } else { $tb.AutoCompleteMode = 'None' }
    })
    $grid.Add_CellMouseEnter({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { Set-CrossHover $e.RowIndex $true } })
    $grid.Add_CellMouseLeave({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { Set-CrossHover $e.RowIndex $false } })
    $grid.Add_CellClick({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { $grid.Rows.RemoveAt($e.RowIndex); $grid.Cursor = 'Default'; Save-AliasGrid } })

    $foot.Open.Add_LinkClicked({ Start-Process notepad.exe "`"$aliasFile`"" })
    $foot.Done.Add_Click({ $f.Close() })
    $f.Add_KeyDown({ param($sender, $e)
        if ($e.KeyCode -ne 'Escape' -or $grid.IsCurrentCellInEditMode) { return }
        $e.SuppressKeyPress = $true
        Undo-AliasField
    })
    # alias.txt edited by hand meanwhile: reload
    $f.Add_Activated({ if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasMgrStamp) { Update-Aliases; Import-AliasGrid } })
    $f.Add_Shown({
        [LauncherNative]::Placeholder($aliasBox.Handle, 'Alias'); [LauncherNative]::Placeholder($targetBox.Handle, 'App, folder, URL or command')
        foreach ($c in $grid.Controls) { [LauncherNative]::DarkScroll($c.Handle) }
        if ($preset) { $targetBox.Text = $preset }
        $f.Activate(); $aliasBox.Focus()   # opens in front, without being stuck there
        # ShowDialog disabled the bar: enable it again so a new alias can be tried in the bar right away
        foreach ($w in @($bar, $pop)) { if ($w) { [LauncherNative]::Enable($w.Handle) } }
    })
}

# ---- The window ----

# $preset: name of an app to pre-fill as the target
function Show-AliasManager([string]$preset) {
    # Already open (":alias" typed again...): bring it forward instead of opening another
    if ($script:aliasWin -and $script:aliasWin.Visible) {
        if ($preset) { $script:aliasTarget.Text = $preset; $script:aliasKey.Focus() }
        $script:aliasWin.Activate(); return
    }
    $f = New-AliasForm
    $names = New-AliasNameList
    $inputRow = New-AliasInputRow $names
    $aliasBox = $inputRow.Alias; $targetBox = $inputRow.Target
    $grid = New-AliasGrid
    $empty = New-AliasEmptyLabel
    $listHost = New-Object Windows.Forms.Panel
    $listHost.Dock = 'Fill'; $listHost.Padding = New-Object Windows.Forms.Padding((px 20), 0, (px 20), 0)
    $listHost.Controls.AddRange(@($grid, $empty))
    $foot = New-AliasFooter
    $f.Controls.AddRange(@($listHost, $inputRow.Panel, (New-AliasHeader), $foot.Panel))   # Fill first: docked last, takes what's left
    Register-AliasEvents

    Update-AppsIfStale   # alias.txt edited by hand since the last load: every alias gets its icon
    Import-AliasGrid
    [void]$f.Handle; [LauncherNative]::DarkTitle($f.Handle)
    $script:aliasWin = $f; $script:aliasTarget = $targetBox; $script:aliasKey = $aliasBox
    try { [void]$f.ShowDialog((New-Object DesktopOwner)) } finally { $script:aliasWin = $null }
}
