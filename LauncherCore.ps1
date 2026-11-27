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
        if (res.Count == 0) res = tasks.Count > 0 ? tasks : weak;
        // best score first, then the shortest name (Excel before Exceed Share)
        res.Sort((x, y) => y[1] != x[1] ? y[1].CompareTo(x[1])
                         : keys[x[0]].Length != keys[y[0]].Length ? keys[x[0]].Length.CompareTo(keys[y[0]].Length)
                         : string.CompareOrdinal(keys[x[0]], keys[y[0]]));
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
}

function New-Entry($name, $id, $kind, $target = $null, $iconPath = $null, $shell = $null) {
    [pscustomobject]@{ Name = $name; Id = $id; Kind = $kind; Target = $target; IconPath = $iconPath; Shell = $shell; Key = (ConvertTo-Key $name); Aliases = @() }
}

function Import-Apps {
    $list = @(Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique | ForEach-Object { New-Entry $_.Name $_.AppID 'App' })
    $taken = @{}; foreach ($a in $list) { $taken[$a.Key] = $true }
    # Personal shortcuts: name = file name without extension ("C411.lnk" -> "C411")
    foreach ($f in Get-ShortcutFiles) { $list += New-Entry $f.BaseName $f.FullName 'Shortcut' $f.FullName }
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
    foreach ($p in $settingsPages.GetEnumerator()) {
        if ($taken[(ConvertTo-Key $p.Key)]) { continue }
        $list += New-Entry $p.Key "ms-settings:$($p.Value)" 'Settings' "ms-settings:$($p.Value)" $settingsIcon
    }
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

# ---- Alias manager window ----
# $preset: name of an app to pre-fill in a new row
function Show-AliasManager([string]$preset) {
    $f = New-Object Windows.Forms.Form
    $f.Text = 'Launcher aliases'
    $f.StartPosition = 'CenterScreen'
    $f.Size = New-Object Drawing.Size(560, 480)
    $f.MinimumSize = New-Object Drawing.Size(400, 300)
    $f.TopMost = $true
    $f.MinimizeBox = $false
    $f.Font = New-Object Drawing.Font('Segoe UI', 10)

    $info = New-Object Windows.Forms.Label
    $info.Dock = 'Top'
    $info.Height = 46
    $info.Padding = New-Object Windows.Forms.Padding(8, 6, 8, 0)
    $info.Text = "Alias = what you type in the bar.  Target = the app (suggested as you type), a folder, a URL or a command."

    $grid = New-Object Windows.Forms.DataGridView
    $grid.Dock = 'Fill'
    $grid.RowHeadersVisible = $false
    $grid.AllowUserToAddRows = $true
    $grid.AutoSizeColumnsMode = 'Fill'
    $grid.BackgroundColor = [Drawing.Color]::White
    $grid.BorderStyle = 'None'
    [void]$grid.Columns.Add('Alias', 'Alias')
    [void]$grid.Columns.Add('Target', 'Target')
    $grid.Columns[0].FillWeight = 30
    $grid.Columns[1].FillWeight = 70

    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        [void]$grid.Rows.Add($Matches[1], $Matches[2])
    }
    if ($preset) {
        $i = $grid.Rows.Add('', $preset)
        $grid.CurrentCell = $grid.Rows[$i].Cells[0]
        $f.Add_Shown({ $grid.BeginEdit($true) })
    }

    # App name suggestions in the Target column
    $names = New-Object Windows.Forms.AutoCompleteStringCollection
    $names.AddRange([string[]]@($script:apps | Where-Object { -not $_.Target } | ForEach-Object { $_.Name }))
    $grid.Add_EditingControlShowing({
        param($s, $e)
        $tb = $e.Control -as [Windows.Forms.TextBox]
        if (-not $tb) { return }
        if ($grid.CurrentCell.ColumnIndex -eq 1) {
            $tb.AutoCompleteMode = 'SuggestAppend'; $tb.AutoCompleteSource = 'CustomSource'; $tb.AutoCompleteCustomSource = $names
        } else { $tb.AutoCompleteMode = 'None' }
    })

    $bottom = New-Object Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Bottom'
    $bottom.Height = 48
    $bottom.FlowDirection = 'RightToLeft'
    $bottom.Padding = New-Object Windows.Forms.Padding(6)

    $save = New-Object Windows.Forms.Button; $save.Text = 'Save'; $save.Width = 110; $save.Height = 32
    $cancel = New-Object Windows.Forms.Button; $cancel.Text = 'Cancel'; $cancel.Width = 90; $cancel.Height = 32
    $del = New-Object Windows.Forms.Button; $del.Text = 'Delete row'; $del.Width = 150; $del.Height = 32
    $bottom.Controls.AddRange(@($save, $cancel, $del))

    $del.Add_Click({
        $r = $grid.CurrentRow
        if ($r -and -not $r.IsNewRow) { $grid.Rows.Remove($r) }
    })
    $cancel.Add_Click({ $f.Close() })
    $save.Add_Click({
        [void]$grid.EndEdit()
        $out = @($aliasHeader)
        foreach ($r in $grid.Rows) {
            if ($r.IsNewRow) { continue }
            $a = "$($r.Cells[0].Value)".Trim(); $c = "$($r.Cells[1].Value)".Trim()
            if ($a -and $c) { $out += "$a = $c" }
        }
        $out | Set-Content -Encoding UTF8 $aliasFile
        Import-Apps
        $f.Close()
    })

    $f.Controls.Add($grid)
    $f.Controls.Add($info)
    $f.Controls.Add($bottom)
    [void]$f.ShowDialog()
}

Import-Apps
