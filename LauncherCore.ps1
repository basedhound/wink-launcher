# Launcher core: app list, aliases, search, launching, usage history, alias manager window.
# Dot-sourced by LauncherBar.ps1 (which defines Write-Log).

$dataDir   = Join-Path $env:APPDATA 'Launcher'
$histFile  = Join-Path $dataDir 'history.json'
$aliasFile = Join-Path $PSScriptRoot 'alias.txt'
$shortcutDir = Join-Path $PSScriptRoot 'shortcuts'   # any file dropped here (.lnk, .url, .exe, document...) shows up in the search
New-Item -ItemType Directory -Force $dataDir, $shortcutDir | Out-Null

# Files in the shortcuts folder (subfolders included), except dot-files such as .gitkeep
function Get-ShortcutFiles { @(Get-ChildItem -LiteralPath $shortcutDir -File -Recurse -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') }) }
# Changes when a shortcut is added, removed, renamed or edited
function Get-ShortcutStamp { (Get-ShortcutFiles | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';' }

$aliasHeader = @(
    '# Launcher aliases: one alias per line, in the form   alias = target'
    '# The target can be the exact name of a Start menu app, a path, a URL or a command.'
    '# Type ":alias" in the bar to open the alias manager.'
)

$script:hist = @{}
if (Test-Path $histFile) {
    try { (Get-Content $histFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $script:hist[$_.Name] = [int]$_.Value } } catch {}
}

if (-not (Test-Path $aliasFile)) {
    $aliasHeader + @('w = Word', 'x = Excel', 'calc = Calculator', 'note = Notepad') | Set-Content -Encoding UTF8 $aliasFile
}

# Search in C#: instant even with hundreds of apps
if (-not ('LauncherSearch' -as [type])) {
Add-Type -TypeDefinition @'
using System; using System.Text; using System.Globalization; using System.Collections.Generic;
public static class LauncherSearch {
    public static string Key(string s) {
        var d = (s ?? "").ToLowerInvariant().Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder(d.Length);
        foreach (char c in d) if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark) sb.Append(c);
        return sb.ToString();
    }
    static readonly char[] Sep = { ' ', '-', '_', '.', '(', ')' };
    // Strong matches (>= 200) start like the text: the name, a word of it, or its initials.
    // Weak matches (< 200) are only used when nothing strong matches.
    public static int Score(string n, string q) {
        if (n == q) return 1000;
        if (n.StartsWith(q, StringComparison.Ordinal)) return 800;
        var words = n.Split(Sep, StringSplitOptions.RemoveEmptyEntries);
        if (string.Concat(words).StartsWith(q, StringComparison.Ordinal)) return 700;   // "wifi" -> "Wi-Fi"
        // the text starting at a word (several words allowed: "hidden files"); the earlier the word, the better
        // ("YouTube Playlist" before "VLC media player")
        for (int p = n.IndexOf(q, StringComparison.Ordinal); p >= 0; p = n.IndexOf(q, p + 1, StringComparison.Ordinal))
            if (p == 0 || Array.IndexOf(Sep, n[p - 1]) >= 0)
                return 600 - 20 * Math.Min(n.Substring(0, p).Split(Sep, StringSplitOptions.RemoveEmptyEntries).Length, 5);
        var ini = new StringBuilder();
        foreach (var w in words) ini.Append(w[0]);
        if (q.Length >= 2 && ini.ToString().StartsWith(q, StringComparison.Ordinal)) return 450;   // "vsc" -> Visual Studio Code
        if (n.IndexOf(q, StringComparison.Ordinal) >= 0) return 150;   // inside a word (weak)
        // letters in order (weak), starting at the beginning of a word: "ntpd" -> Notepad,
        // but not "sarv" -> windowS AdministRatiVe Tools (letters picked from anywhere in a long name)
        for (int p = 0; p < n.Length; p++) {
            if (n[p] != q[0] || (p > 0 && Array.IndexOf(Sep, n[p - 1]) < 0)) continue;
            int i = 0;
            for (int k = p; k < n.Length && i < q.Length; k++) if (n[k] == q[i]) i++;
            if (i == q.Length) return 100;
        }
        return 0;
    }
    // aliases[i] = aliases separated by '|'
    // bonus[i] = ranking offset for the kind of result (apps 0, Control Panel tasks negative...)
    public static int[] Find(string[] keys, string[] aliases, int[] hits, int[] bonus, string text, int max) {
        string q = Key((text ?? "").Trim());
        // Three tiers, each used only if the previous one is empty:
        //   1. apps, shortcuts, Control Panel items, Settings pages starting like the text
        //   2. Control Panel tasks starting like the text (they are long and numerous)
        //   3. weak matches (text inside a word, letters in order) on apps and shortcuts
        var res = new List<int[]>();
        var tasks = new List<int[]>();
        var weak = new List<int[]>();
        for (int i = 0; i < keys.Length; i++) {
            int s = q.Length == 0 ? 1 : Score(keys[i], q);
            if (q.Length > 0 && aliases[i].Length > 0)
                foreach (var a in aliases[i].Split('|')) {
                    if (a == q) s = Math.Max(s, 2000);
                    else if (a.StartsWith(q, StringComparison.Ordinal)) s = Math.Max(s, 900);
                }
            if (s <= 0) continue;
            var r = new[] { i, Math.Max(1, s + bonus[i]) + Math.Min(300, 25 * hits[i]) };
            if (q.Length == 0) { res.Add(r); continue; }
            if (s < 200) { if (bonus[i] == 0) weak.Add(r); }
            else if (bonus[i] <= -200) tasks.Add(r);
            else res.Add(r);
        }
        // best score first, then the shortest name (Excel before Exceed Share)
        Comparison<int[]> order = (x, y) => y[1] != x[1] ? y[1].CompareTo(x[1])
                         : keys[x[0]].Length != keys[y[0]].Length ? keys[x[0]].Length.CompareTo(keys[y[0]].Length)
                         : string.CompareOrdinal(keys[x[0]], keys[y[0]]);
        if (res.Count == 0) res = tasks.Count > 0 ? tasks : weak;
        res.Sort(order);
        var o = new int[Math.Min(max, res.Count)];
        for (int i = 0; i < o.Length; i++) o[i] = res[i][0];
        return o;
    }
}
'@
}

function ConvertTo-Key([string]$s) { [LauncherSearch]::Key($s) }

# Result kinds (shown as a small grey tag next to non-app results) and their ranking offset:
# on equal match quality, apps come first and Control Panel tasks (long, numerous) last.
$kindBonus = @{ 'App' = 0; 'Shortcut' = 0; 'Command' = 0; 'Control Panel' = -50; 'Settings' = -50; 'Control Panel task' = -250 }
$cplIcon      = '::{26EE0668-A00A-44D7-9371-BEB064C98683}'
$settingsIcon = 'shell:AppsFolder\windows.immersivecontrolpanel_cw5n1h2txyewy!microsoft.windows.immersivecontrolpanel'

# Common Settings pages (Windows has no API to list them): name = ms-settings page
$settingsPages = [ordered]@{
    'Display' = 'display'; 'Night light' = 'nightlight'; 'Sound' = 'sound'; 'Notifications & actions' = 'notifications'
    'Focus assist' = 'quiethours'; 'Power & sleep' = 'powersleep'; 'Storage' = 'storagesense'; 'Multitasking' = 'multitasking'
    'Clipboard' = 'clipboard'; 'Remote Desktop' = 'remotedesktop'; 'About this PC' = 'about'
    'Bluetooth & other devices' = 'bluetooth'; 'Printers & scanners' = 'printers'; 'Mouse' = 'mousetouchpad'; 'Typing' = 'typing'
    'AutoPlay' = 'autoplay'; 'Network status' = 'network-status'; 'Wi-Fi' = 'network-wifi'; 'Ethernet' = 'network-ethernet'
    'VPN' = 'network-vpn'; 'Proxy' = 'network-proxy'; 'Background' = 'personalization-background'; 'Colors' = 'colors'
    'Lock screen' = 'lockscreen'; 'Themes' = 'themes'; 'Fonts' = 'fonts'; 'Start menu settings' = 'personalization-start'
    'Taskbar settings' = 'taskbar'; 'Apps & features' = 'appsfeatures'; 'Default apps' = 'defaultapps'; 'Startup apps' = 'startupapps'
    'Your info' = 'yourinfo'; 'Sign-in options' = 'signinoptions'; 'Date & time' = 'dateandtime'; 'Region' = 'regionformatting'
    'Language' = 'regionlanguage'; 'Speech' = 'speech'; 'Game Mode' = 'gaming-gamemode'; 'Xbox Game Bar' = 'gaming-gamebar'
    'Keyboard accessibility' = 'easeofaccess-keyboard'; 'Mouse pointer' = 'easeofaccess-mousepointer'; 'Text size' = 'easeofaccess-display'
    'Privacy' = 'privacy'; 'Microphone privacy' = 'privacy-microphone'; 'Camera privacy' = 'privacy-webcam'; 'Location privacy' = 'privacy-location'
    'Windows Update' = 'windowsupdate'; 'Windows Security' = 'windowsdefender'; 'Backup' = 'backup'; 'Troubleshoot' = 'troubleshoot'
    'Recovery' = 'recovery'; 'Activation' = 'activation'; 'For developers' = 'developers'
    # Other names Windows Search knows these pages by
    'Add or remove programs' = 'appsfeatures'; 'Uninstall apps' = 'appsfeatures'; 'Remove a device' = 'bluetooth'
    'Add a device' = 'bluetooth'; 'Change your background' = 'personalization-background'; 'Screen resolution' = 'display'
    'Check for updates' = 'windowsupdate'; 'Reset this PC' = 'recovery'; 'Optional features' = 'optionalfeatures'
}

function New-Entry($name, $id, $kind, $target = $null, $iconPath = $null, $shell = $null) {
    [pscustomobject]@{ Name = $name; Id = $id; Kind = $kind; Target = $target; IconPath = $iconPath; Shell = $shell; Key = (ConvertTo-Key $name); Aliases = @() }
}

function Import-Apps {
    $list = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object { New-Entry $_.Name $_.AppID 'App' })
    $taken = @{}; foreach ($a in $list) { $taken[$a.Key] = $true }
    # Personal shortcuts: name = file name without extension ("C411.lnk" -> "C411")
    foreach ($f in Get-ShortcutFiles) { $list += New-Entry $f.BaseName $f.FullName 'Shortcut' $f.FullName }
    # Settings pages before Control Panel: "Add or remove programs" opens the modern page, as in Windows Search
    foreach ($p in $settingsPages.GetEnumerator()) {
        $k = ConvertTo-Key $p.Key
        if ($taken[$k]) { continue }
        $taken[$k] = $true
        $list += New-Entry $p.Key "ms-settings:$($p.Value)" 'Settings' "ms-settings:$($p.Value)" $settingsIcon
    }
    # Control Panel items (Indexing Options, Power Options...) and tasks ("Change how your mouse works"...), like Windows Search.
    # Opened through their shell item, which needs an STA thread (the bar's is).
    try {
        $sh = New-Object -ComObject Shell.Application
        foreach ($src in @(@("shell:$cplIcon\0", 'Control Panel'), @('shell:::{ED7BA470-8E54-465E-825C-99712043E01C}', 'Control Panel task'))) {
            $ns = $sh.Namespace($src[0]); if (-not $ns) { continue }
            foreach ($it in $ns.Items()) {
                $k = ConvertTo-Key $it.Name
                if (-not $it.Name -or $taken[$k]) { continue }   # skip duplicates of a Start menu app
                $taken[$k] = $true
                $icon = if ($src[1] -eq 'Control Panel') { $it.Path } else { $cplIcon }
                $list += New-Entry $it.Name $it.Path $src[1] $null $icon $it
            }
        }
    } catch {}
    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        $alias = ConvertTo-Key $Matches[1]; $target = $Matches[2]
        $app = $list | Where-Object { $_.Name -eq $target } | Select-Object -First 1
        if (-not $app -and $target -notmatch '[\\/:.]') {
            $app = $list | Where-Object { -not $_.Target -and $_.Name -like "$target*" } | Sort-Object { $_.Name.Length } | Select-Object -First 1
        }
        if (-not $app) {
            $app = New-Entry $target $target 'Command' $target
            $list += $app
        }
        $app.Aliases += $alias
    }
    $script:apps = $list
    $script:keys = [string[]]@($list | ForEach-Object { $_.Key })
    $script:aliasArr = [string[]]@($list | ForEach-Object { $_.Aliases -join '|' })
    $script:hits = [int[]]@($list | ForEach-Object { [int]$script:hist[$_.Id] })
    $script:bonus = [int[]]@($list | ForEach-Object { [int]$kindBonus[$_.Kind] })
    for ($i = 0; $i -lt $list.Count; $i++) { $list[$i] | Add-Member -NotePropertyName Idx -NotePropertyValue $i -Force }
    $script:aliasStamp = (Get-Item $aliasFile).LastWriteTime
    $script:shortcutStamp = Get-ShortcutStamp
}

# Reloads only if alias.txt or the shortcuts folder changed (the full list is refreshed in the background by the bar)
function Update-AppsIfStale {
    if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasStamp -or (Get-ShortcutStamp) -ne $script:shortcutStamp) { Import-Apps }
}

# Callers must wrap the result in @(...): with a single match PowerShell 5.1 returns the object alone, with no .Count
function Find-Apps([string]$text, [int]$max = 15) {
    $idx = [LauncherSearch]::Find($script:keys, $script:aliasArr, $script:hits, $script:bonus, $text, $max)
    @(foreach ($i in $idx) { $script:apps[$i] })
}

function Get-AppLabel($a) {
    if ($a.Aliases.Count) { return $a.Name + '    [' + ($a.Aliases -join ', ') + ']' }
    $a.Name
}

# Launches the app (or, if $app is empty, the typed text: path, URL, command). Returns $true on success.
function Invoke-Launch($app, [string]$text) {
    $text = $text.Trim()
    try {
        if ($text -eq ':alias') { Show-AliasManager; return $true }
        if ($app) {
            Write-Log "Launch: $($app.Name) [$($app.Kind) $($app.Id)]"
            if ($app.Shell) { $app.Shell.InvokeVerb() }                                    # Control Panel item / task
            elseif ($app.Kind -eq 'Settings') { [void][Diagnostics.Process]::Start($app.Target) }   # ms-settings: page
            elseif ($app.Target) { Start-Process $app.Target }
            else { Start-Process explorer.exe "shell:AppsFolder\$($app.Id)" }
            $script:hist[$app.Id] = [int]$script:hist[$app.Id] + 1
            $script:hits[$app.Idx] = $script:hist[$app.Id]
            try { $script:hist | ConvertTo-Json | Set-Content -Encoding UTF8 $histFile } catch {}
            return $true
        }
        if ($text) { Start-Process $text; return $true }
    } catch {
        Write-Log "Launch failed: $(if ($app) { "$($app.Name) [$($app.Id)]" } else { $text }): $($_.Exception.Message)"
        [Windows.Forms.MessageBox]::Show("Couldn't launch: $(if ($app) { $app.Name } else { $text })", 'Launcher') | Out-Null
    }
    $false
}

# Adds (or replaces) an alias in alias.txt
function Add-Alias([string]$alias, [string]$target) {
    $alias = $alias.Trim(); $target = $target.Trim()
    if (-not $alias -or -not $target) { return }
    $k = ConvertTo-Key $alias
    $keep = foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -notmatch '^\s*#' -and $line -match '^\s*([^=]+?)\s*=' -and (ConvertTo-Key $Matches[1]) -eq $k) { continue }
        $line
    }
    @($keep) + "$alias = $target" | Set-Content -Encoding UTF8 $aliasFile
    Import-Apps
}

# ---- Alias manager window (dark) ----
# Changes are saved as soon as they're made: add a row at the top, edit a cell (double-click), or click the cross.
# $preset: name of an app to pre-fill as the target (right-click a suggestion > Give this app an alias)
function Show-AliasManager([string]$preset) {
    $s = if ($scale) { $scale } else { 1 }
    function px([double]$v) { [int]($v * $s) }
    $cBg = [Drawing.Color]::FromArgb(32, 32, 32); $cIn = [Drawing.Color]::FromArgb(45, 45, 45); $cInHover = [Drawing.Color]::FromArgb(58, 58, 58)
    $cLine = [Drawing.Color]::FromArgb(52, 52, 52); $cSel = [Drawing.Color]::FromArgb(42, 46, 54)
    $cText = [Drawing.Color]::FromArgb(232, 232, 232); $cMuted = [Drawing.Color]::FromArgb(150, 150, 150)
    $cAlias = [Drawing.Color]::FromArgb(140, 180, 245); $cAcc = [Drawing.Color]::FromArgb(60, 90, 140); $cAccHover = [Drawing.Color]::FromArgb(76, 110, 166)
    $cDel = [Drawing.Color]::FromArgb(232, 80, 90)
    $font = New-Object Drawing.Font('Segoe UI', 10)
    $blank = New-Object Drawing.Bitmap(1, 1)

    # Rounded corners on a control (redone when it's resized)
    $round = {
        $c = $this; $r = px 6; $w = $c.Width; $h = $c.Height; if ($w -lt $r * 2 -or $h -lt $r * 2) { return }
        $p = New-Object Drawing.Drawing2D.GraphicsPath
        $p.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $p.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
        $p.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90); $p.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
        $p.CloseFigure(); $c.Region = New-Object Drawing.Region($p)
    }
    function New-Button([string]$text, $back, $hover) {
        $b = New-Object Windows.Forms.Button
        $b.Text = $text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
        $b.BackColor = $back; $b.FlatAppearance.MouseOverBackColor = $hover; $b.FlatAppearance.MouseDownBackColor = $hover
        $b.ForeColor = [Drawing.Color]::White; $b.Cursor = 'Hand'; $b.Add_Resize($round); $b
    }
    # Text field: a borderless text box inside a rounded panel, vertically centered
    function New-Field {
        $p = New-Object Windows.Forms.Panel
        $p.Dock = 'Fill'; $p.BackColor = $cIn; $p.Margin = New-Object Windows.Forms.Padding(0, 0, (px 8), 0); $p.Cursor = 'IBeam'
        $t = New-Object Windows.Forms.TextBox
        $t.BorderStyle = 'None'; $t.BackColor = $cIn; $t.ForeColor = $cText; $t.Font = $font
        $p.Controls.Add($t)
        $p.Add_Resize({ $tb = $this.Controls[0]; $tb.SetBounds((px 10), [int](($this.Height - $tb.Height) / 2), $this.Width - (px 20), $tb.Height) })
        $p.Add_Resize($round)
        $p.Add_Click({ $this.Controls[0].Focus() })
        $p
    }

    $f = New-Object Windows.Forms.Form
    $f.Text = 'Aliases'; $f.ShowIcon = $false; $f.TopMost = $true; $f.KeyPreview = $true
    $f.StartPosition = 'CenterScreen'; $f.AutoScaleMode = 'None'
    $f.Size = New-Object Drawing.Size((px 640), (px 540)); $f.MinimumSize = New-Object Drawing.Size((px 460), (px 360))
    $f.BackColor = $cBg; $f.ForeColor = $cText; $f.Font = $font

    # Header
    $head = New-Object Windows.Forms.Panel
    $head.Dock = 'Top'; $head.Height = px 82; $head.Padding = New-Object Windows.Forms.Padding((px 20), (px 16), (px 20), 0)
    $sub = New-Object Windows.Forms.Label
    $sub.Dock = 'Top'; $sub.Height = px 24; $sub.ForeColor = $cMuted; $sub.Font = New-Object Drawing.Font('Segoe UI', 9.5)
    $sub.Text = 'Type an alias in the bar to launch its target: an app, a folder, a URL or a command.'
    $title = New-Object Windows.Forms.Label
    $title.Dock = 'Top'; $title.Height = px 34; $title.Text = 'Aliases'; $title.ForeColor = [Drawing.Color]::White
    $title.Font = New-Object Drawing.Font('Segoe UI Semibold', 16)
    $head.Controls.AddRange(@($sub, $title))

    # New alias row: [alias] [target] [Add]
    $add = New-Object Windows.Forms.TableLayoutPanel
    $add.Dock = 'Top'; $add.Height = px 58; $add.Padding = New-Object Windows.Forms.Padding((px 20), (px 8), (px 20), (px 10))
    $add.ColumnCount = 3; $add.RowCount = 1
    [void]$add.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 30)))
    [void]$add.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Percent', 70)))
    [void]$add.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle('Absolute', (px 90))))
    [void]$add.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100)))
    $aliasField = New-Field; $aliasBox = $aliasField.Controls[0]
    $targetField = New-Field; $targetBox = $targetField.Controls[0]
    $names = New-Object Windows.Forms.AutoCompleteStringCollection
    $names.AddRange([string[]]@($script:apps | Where-Object { -not $_.Target } | ForEach-Object { $_.Name }))
    $targetBox.AutoCompleteMode = 'SuggestAppend'; $targetBox.AutoCompleteSource = 'CustomSource'; $targetBox.AutoCompleteCustomSource = $names
    $addBtn = New-Button 'Add' $cAcc $cAccHover
    $addBtn.Dock = 'Fill'; $addBtn.Margin = New-Object Windows.Forms.Padding(0)
    $add.Controls.Add($aliasField, 0, 0); $add.Controls.Add($targetField, 1, 0); $add.Controls.Add($addBtn, 2, 0)

    # Alias list
    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'; $grid.BackgroundColor = $cBg; $grid.BorderStyle = 'None'; $grid.GridColor = $cLine
    $grid.CellBorderStyle = 'SingleHorizontal'; $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $false; $grid.AllowUserToDeleteRows = $false; $grid.AllowUserToResizeRows = $false
    $grid.SelectionMode = 'FullRowSelect'; $grid.MultiSelect = $false; $grid.AutoSizeColumnsMode = 'Fill'
    $grid.EnableHeadersVisualStyles = $false; $grid.ColumnHeadersBorderStyle = 'None'
    $grid.ColumnHeadersHeightSizeMode = 'DisableResizing'; $grid.ColumnHeadersHeight = px 32
    $grid.RowTemplate.Height = px 42; $grid.EditMode = 'EditProgrammatically'
    $grid.DefaultCellStyle.BackColor = $cBg; $grid.DefaultCellStyle.ForeColor = $cText
    $grid.DefaultCellStyle.SelectionBackColor = $cSel; $grid.DefaultCellStyle.SelectionForeColor = [Drawing.Color]::White
    $grid.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding((px 4), 0, 0, 0)
    $grid.ColumnHeadersDefaultCellStyle.BackColor = $cBg; $grid.ColumnHeadersDefaultCellStyle.ForeColor = $cMuted
    $grid.ColumnHeadersDefaultCellStyle.SelectionBackColor = $cBg; $grid.ColumnHeadersDefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI', 9)
    $grid.ColumnHeadersDefaultCellStyle.Padding = New-Object Windows.Forms.Padding((px 4), 0, 0, 0)
    $colIcon = New-Object Windows.Forms.DataGridViewImageColumn
    $colIcon.HeaderText = ''; $colIcon.AutoSizeMode = 'None'; $colIcon.Width = px 46; $colIcon.ImageLayout = 'Zoom'; $colIcon.ReadOnly = $true
    $colIcon.DefaultCellStyle.Padding = New-Object Windows.Forms.Padding((px 14), (px 11), (px 4), (px 11)); $colIcon.DefaultCellStyle.NullValue = $blank
    $colAlias = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $colAlias.HeaderText = 'ALIAS'; $colAlias.FillWeight = 30
    $colAlias.DefaultCellStyle.ForeColor = $cAlias; $colAlias.DefaultCellStyle.SelectionForeColor = $cAlias
    $colAlias.DefaultCellStyle.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $colTarget = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $colTarget.HeaderText = 'TARGET'; $colTarget.FillWeight = 70
    $colDel = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $colDel.HeaderText = ''; $colDel.AutoSizeMode = 'None'; $colDel.Width = px 46; $colDel.ReadOnly = $true
    $colDel.DefaultCellStyle.Alignment = 'MiddleCenter'; $colDel.DefaultCellStyle.ForeColor = $cMuted; $colDel.DefaultCellStyle.SelectionForeColor = $cMuted
    $grid.Columns.AddRange([Windows.Forms.DataGridViewColumn[]]@($colIcon, $colAlias, $colTarget, $colDel))
    foreach ($c in $grid.Columns) { $c.SortMode = 'NotSortable'; $c.Resizable = 'False' }
    $cross = [string][char]0x2715

    $empty = New-Object Windows.Forms.Label
    $empty.Dock = 'Fill'; $empty.TextAlign = 'MiddleCenter'; $empty.ForeColor = $cMuted; $empty.BackColor = $cBg
    $empty.Text = "No aliases yet.`nAdd one above, for example  ch  " + [char]0x2192 + "  Google Chrome."
    $listHost = New-Object Windows.Forms.Panel
    $listHost.Dock = 'Fill'; $listHost.Padding = New-Object Windows.Forms.Padding((px 20), 0, (px 20), 0)
    $listHost.Controls.AddRange(@($grid, $empty))

    # Footer: open alias.txt / Done
    $foot = New-Object Windows.Forms.Panel
    $foot.Dock = 'Bottom'; $foot.Height = px 60; $foot.Padding = New-Object Windows.Forms.Padding((px 20), (px 12), (px 20), (px 14))
    $done = New-Button 'Done' $cIn $cInHover
    $done.Dock = 'Right'; $done.Width = px 96
    $open = New-Object Windows.Forms.LinkLabel
    $open.Dock = 'Left'; $open.AutoSize = $false; $open.Width = px 200; $open.TextAlign = 'MiddleLeft'; $open.Text = 'Open alias.txt'
    $open.LinkColor = $cMuted; $open.ActiveLinkColor = [Drawing.Color]::White; $open.LinkBehavior = 'HoverUnderline'
    $foot.Controls.AddRange(@($done, $open))

    $f.Controls.AddRange(@($listHost, $add, $head, $foot))   # Fill first: docked last, takes what's left

    # ---- Behaviour ----
    function Get-AliasIcon([string]$alias) {
        $k = ConvertTo-Key $alias
        $a = $script:apps | Where-Object { $_.Aliases -contains $k } | Select-Object -First 1
        $img = if ($a) { Get-AppIcon $a }
        if ($img) { $img } else { $blank }
    }
    function Import-AliasGrid {
        $grid.Rows.Clear()
        foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
            if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
            [void]$grid.Rows.Add((Get-AliasIcon $Matches[1]), $Matches[1], $Matches[2], $cross)
        }
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
        Import-Apps
        foreach ($r in $grid.Rows) { $r.Cells[0].Value = Get-AliasIcon "$($r.Cells[1].Value)" }
        $empty.Visible = $grid.Rows.Count -eq 0
        $script:aliasMgrStamp = (Get-Item $aliasFile).LastWriteTime
    }
    $addAlias = {
        $a = $aliasBox.Text.Trim(); $t = $targetBox.Text.Trim()
        if (-not $a) { $aliasBox.Focus(); return }
        if (-not $t) { $targetBox.Focus(); return }
        $k = ConvertTo-Key $a
        foreach ($r in @($grid.Rows)) { if ((ConvertTo-Key "$($r.Cells[1].Value)") -eq $k) { $grid.Rows.Remove($r) } }   # same alias: replaced
        $i = $grid.Rows.Add($blank, $a, $t, $cross)
        Save-AliasGrid
        $aliasBox.Text = ''; $targetBox.Text = ''; $aliasBox.Focus()
        $grid.ClearSelection(); $grid.Rows[$i].Selected = $true; $grid.FirstDisplayedScrollingRowIndex = $i
    }
    $addBtn.Add_Click($addAlias)
    $enter = { param($sender, $e) if ($e.KeyCode -eq 'Return') { $e.SuppressKeyPress = $true; & $addAlias } }
    $aliasBox.Add_KeyDown($enter); $targetBox.Add_KeyDown($enter)

    # Double-click (or F2) a cell to edit it; saved when the edit ends. Emptied alias or target: row removed.
    $grid.Add_CellDoubleClick({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -in 1, 2) { $grid.BeginEdit($true) } })
    $grid.Add_KeyDown({ param($sender, $e)
        if ($e.KeyCode -eq 'F2' -and $grid.CurrentCell -and $grid.CurrentCell.ColumnIndex -in 1, 2) { $grid.BeginEdit($true); $e.Handled = $true }
        elseif ($e.KeyCode -eq 'Delete' -and $grid.CurrentRow) { $grid.Rows.Remove($grid.CurrentRow); Save-AliasGrid; $e.Handled = $true }
    })
    $grid.Add_CellEndEdit({ param($sender, $e)
        $r = $grid.Rows[$e.RowIndex]
        if (-not "$($r.Cells[1].Value)".Trim() -or -not "$($r.Cells[2].Value)".Trim()) { $grid.BeginInvoke([Action]{ $grid.Rows.Remove($r); Save-AliasGrid }) | Out-Null }
        else { Save-AliasGrid }
    })
    $grid.Add_EditingControlShowing({ param($sender, $e)
        $tb = $e.Control -as [Windows.Forms.TextBox]; if (-not $tb) { return }
        $tb.BackColor = $cIn; $tb.ForeColor = $cText
        if ($grid.CurrentCell.ColumnIndex -eq 2) { $tb.AutoCompleteMode = 'SuggestAppend'; $tb.AutoCompleteSource = 'CustomSource'; $tb.AutoCompleteCustomSource = $names }
        else { $tb.AutoCompleteMode = 'None' }
    })
    # Cross: delete the row (red on hover)
    $grid.Add_CellMouseEnter({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { $c = $grid.Rows[$e.RowIndex].Cells[3]; $c.Style.ForeColor = $cDel; $c.Style.SelectionForeColor = $cDel; $grid.Cursor = 'Hand' } })
    $grid.Add_CellMouseLeave({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { $c = $grid.Rows[$e.RowIndex].Cells[3]; $c.Style.ForeColor = $cMuted; $c.Style.SelectionForeColor = $cMuted; $grid.Cursor = 'Default' } })
    $grid.Add_CellClick({ param($sender, $e) if ($e.RowIndex -ge 0 -and $e.ColumnIndex -eq 3) { $grid.Rows.RemoveAt($e.RowIndex); $grid.Cursor = 'Default'; Save-AliasGrid } })

    $open.Add_LinkClicked({ Start-Process notepad.exe "`"$aliasFile`"" })
    $done.Add_Click({ $f.Close() })
    # Esc: clears the field being typed in (and its suggestion list) first, closes the window when it's empty
    $f.Add_KeyDown({ param($sender, $e)
        if ($e.KeyCode -ne 'Escape' -or $grid.IsCurrentCellInEditMode) { return }
        $e.SuppressKeyPress = $true
        $tb = $f.ActiveControl -as [Windows.Forms.TextBox]
        if ($tb -and $tb.Text) { $tb.Text = '' } else { $f.Close() }
    })
    # alias.txt edited by hand meanwhile: reload
    $f.Add_Activated({ if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasMgrStamp) { Import-Apps; Import-AliasGrid } })
    $f.Add_Shown({
        [LauncherNative]::Placeholder($aliasBox.Handle, 'Alias'); [LauncherNative]::Placeholder($targetBox.Handle, 'App, folder, URL or command')
        foreach ($c in $grid.Controls) { [LauncherNative]::DarkScroll($c.Handle) }
        if ($preset) { $targetBox.Text = $preset }
        $aliasBox.Focus()
    })

    Import-AliasGrid
    [void]$f.Handle; [LauncherNative]::DarkTitle($f.Handle)
    [void]$f.ShowDialog()
}

Import-Apps
