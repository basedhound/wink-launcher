# What the bar can find and launch: Start menu apps, your shortcuts, Settings pages, Control Panel items,
# built-in actions and games, plus aliases, usage history and launching.
# Dot-sourced by LauncherBar.ps1 (which defines Write-Log). Loads the search engine and the game sources.

$appRoot     = Split-Path $PSScriptRoot
$dataDir     = Join-Path $env:APPDATA 'Launcher'
$histFile    = Join-Path $dataDir 'history.json'
$aliasFile   = Join-Path $appRoot 'alias.txt'
$shortcutDir = Join-Path $appRoot 'shortcuts'   # any file dropped here (.lnk, .url, .exe, document...) shows up in the search
New-Item -ItemType Directory -Force $dataDir, $shortcutDir, (Join-Path $shortcutDir '.icons') | Out-Null

if (-not ('LauncherSearch' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'Search.cs') }
. (Join-Path $PSScriptRoot 'Games.ps1')

function ConvertTo-Key([string]$s) { [LauncherSearch]::Key($s) }

# ---- Entries ----

# Result kinds (shown as a small grey tag next to non-app results) and their ranking offset:
# on equal match quality, apps come first ("sl" + Enter opens Slack, not Sleep).
$kindBonus = @{ 'App' = 0; 'Shortcut' = 0; 'Command' = 0; 'Action' = -50; 'Control Panel' = -50; 'Settings' = -50 }

$recycleBin   = '::{645FF040-5081-101B-9F08-00AA002F954E}'   # also its icon (full or empty)
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

# Files in the shortcuts folder (subfolders included), except dot-files and dot-folders
# (".icons" holds the icons used by the shortcuts)
function Get-ShortcutFiles {
    @(Get-ChildItem -LiteralPath $shortcutDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName.Substring($shortcutDir.Length) -notmatch '\\\.' })
}

# Changes when a shortcut is added, removed, renamed or edited
function Get-ShortcutStamp { (Get-ShortcutFiles | ForEach-Object { "$($_.FullName)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';' }

# Personal shortcuts: name = file name without extension ("C411.lnk" -> "C411")
function Get-ShortcutEntries { @(foreach ($f in Get-ShortcutFiles) { New-Entry $f.BaseName $f.FullName 'Shortcut' $f.FullName }) }

function Get-StartMenuApps { Get-StartApps | Where-Object { $_.Name -and $_.AppID } | Sort-Object Name -Unique }

# Changes when Windows' list of Start menu apps changes (it can lag a few seconds behind an uninstall)
function Get-StartMenuStamp { (Get-StartMenuApps | ForEach-Object { $_.AppID }) -join '|' }

# Start menu apps (classic and Store). A shortcut named like an app replaces it (e.g. "Google Calendar"
# opening another page): the shortcut is shown as an app and inherits its launch count.
function Get-StartMenuEntries($shortcuts) {
    $own = @{}
    foreach ($s in $shortcuts) { $own[$s.Key] = $s }
    $startApps = @(Get-StartMenuApps)
    $script:startStamp = ($startApps | ForEach-Object { $_.AppID }) -join '|'
    @($startApps | ForEach-Object {
        $app = New-Entry $_.Name $_.AppID 'App'
        $mine = $own[$app.Key]
        if (-not $mine) { return $app }
        $mine.Kind = 'App'
        if (-not $script:hist[$mine.Id] -and $script:hist[$app.Id]) { $script:hist[$mine.Id] = $script:hist[$app.Id] }
    })
}

# Settings pages not already named by an app ($taken: keys in use, updated)
function Get-SettingsEntries([hashtable]$taken) {
    foreach ($p in $settingsPages.GetEnumerator()) {
        $k = ConvertTo-Key $p.Key
        if ($taken[$k]) { continue }
        $taken[$k] = $true
        New-Entry $p.Key "ms-settings:$($p.Value)" 'Settings' "ms-settings:$($p.Value)" $settingsIcon
    }
}

# Control Panel items (Indexing Options, Power Options...) not already listed ($taken updated).
# Opened through their shell item, which needs an STA thread (the bar's is).
function Get-ControlPanelEntries([hashtable]$taken) {
    try {
        $ns = (New-Object -ComObject Shell.Application).Namespace("shell:$cplIcon\0")
        if (-not $ns) { return }
        foreach ($it in $ns.Items()) {
            $k = ConvertTo-Key $it.Name
            if (-not $it.Name -or $taken[$k]) { continue }
            $taken[$k] = $true
            New-Entry $it.Name $it.Path 'Control Panel' $null $it.Path $it
        }
    } catch {}
}

# Built-in actions: Id -> names it's found by, icon ("file.dll,index" or a shell item), what it does.
# The ones that close your apps ask first (Yes is the default: Enter confirms).
$sys = Join-Path $env:WINDIR 'System32'
$actions = [ordered]@{
    'action:empty-recycle-bin' = @{ Names = @('Empty Recycle Bin'); Icon = $recycleBin; Run = { Invoke-EmptyRecycleBin } }
    'action:shutdown' = @{ Names = @('Shut down', 'Turn off'); Icon = "$sys\shell32.dll,27"
        Run = { if (Confirm-Action 'Shut down' 'Shut down the PC now?') { shutdown.exe /s /t 0 } } }
    'action:restart'  = @{ Names = @('Restart', 'Reboot'); Icon = "$sys\imageres.dll,228"
        Run = { if (Confirm-Action 'Restart' 'Restart the PC now?') { shutdown.exe /r /t 0 } } }
    'action:signout'  = @{ Names = @('Sign out', 'Log off'); Icon = "$sys\shell32.dll,176"
        Run = { if (Confirm-Action 'Sign out' 'Sign out of Windows now?') { shutdown.exe /l } } }
    'action:sleep'    = @{ Names = @('Sleep'); Icon = "$sys\imageres.dll,96"
        Run = { [void][Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) } }
    'action:lock'     = @{ Names = @('Lock'); Icon = "$sys\imageres.dll,54"
        Run = { Start-Process rundll32.exe -ArgumentList 'user32.dll,LockWorkStation' } }
}

function Get-ActionEntries {
    foreach ($id in $actions.Keys) {
        foreach ($name in $actions[$id].Names) { New-Entry $name $id 'Action' $null $actions[$id].Icon }
    }
}

# ---- Aliases ----

$aliasHeader = @(
    '# Launcher aliases: one alias per line, in the form   alias = target'
    '# The target can be the exact name of a Start menu app, a path, a URL or a command.'
    '# Type ":alias" in the bar to open the alias manager.'
)
if (-not (Test-Path $aliasFile)) {
    $aliasHeader + @('w = Word', 'x = Excel', 'calc = Calculator', 'note = Notepad') | Set-Content -Encoding UTF8 $aliasFile
}

# alias.txt -> @{ Alias; Target } for each "alias = target" line (comments skipped)
function Read-Aliases {
    foreach ($line in Get-Content $aliasFile -Encoding UTF8) {
        if ($line -match '^\s*#' -or $line -notmatch '^\s*([^=]+?)\s*=\s*(.+?)\s*$') { continue }
        @{ Alias = $Matches[1]; Target = $Matches[2] }
    }
}

# The entry an alias target names: its exact name, else the shortest name starting like it ("mus" -> Music),
# else none (the target is then a path, URL or command of its own)
function Find-AliasTarget($list, [string]$target) {
    $app = $list | Where-Object { $_.Name -eq $target } | Select-Object -First 1
    if ($app -or $target -match '[\\/:.]') { return $app }
    $tk = ConvertTo-Key $target
    $list | Where-Object { $_.Kind -ne 'Command' -and $_.Key.StartsWith($tk, [StringComparison]::Ordinal) } |
        Sort-Object { $_.Name.Length } | Select-Object -First 1
}

# Attaches each alias to its entry; targets that match nothing become Command entries (added to the list)
function Add-AliasesTo([Collections.ArrayList]$list) {
    foreach ($a in Read-Aliases) {
        $app = Find-AliasTarget $list $a.Target
        if (-not $app) { $app = New-Entry $a.Target $a.Target 'Command' $a.Target; [void]$list.Add($app) }
        $app.Aliases += ConvertTo-Key $a.Alias
    }
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

# ---- Usage history ----

$script:hist = @{}
if (Test-Path $histFile) {
    try { (Get-Content $histFile -Raw | ConvertFrom-Json).psobject.Properties | ForEach-Object { $script:hist[$_.Name] = [int]$_.Value } } catch {}
}

function Add-LaunchCount($app) {
    $script:hist[$app.Id] = [int]$script:hist[$app.Id] + 1
    $script:hits[$app.Idx] = $script:hist[$app.Id]
    try { $script:hist | ConvertTo-Json | Set-Content -Encoding UTF8 $histFile } catch {}
}

# ---- The list ----

# Builds the full list and the arrays the search engine works on
function Import-Apps {
    $shortcuts = @(Get-ShortcutEntries)   # @(): a single shortcut would otherwise come back alone, not as a list
    $list = New-Object Collections.ArrayList
    $list.AddRange(@(Get-StartMenuEntries $shortcuts))
    $list.AddRange($shortcuts)
    $taken = @{}
    foreach ($a in $list) { $taken[$a.Key] = $true }
    $list.AddRange(@(Get-ActionEntries))
    # Settings pages before Control Panel: "Add or remove programs" opens the modern page, as in Windows Search
    $list.AddRange(@(Get-SettingsEntries $taken))
    $list.AddRange(@(Get-ControlPanelEntries $taken))
    try {
        $list.AddRange(@(Get-GameEntries))
        $script:steamStamp = Get-SteamStamp; $script:gogStamp = Get-GogStamp
    } catch { Write-Log "Games not loaded: $($_.Exception.Message)" }
    Add-AliasesTo $list
    Set-SearchIndex @($list)
    $script:aliasStamp = (Get-Item $aliasFile).LastWriteTime
    $script:shortcutStamp = Get-ShortcutStamp
}

function Set-SearchIndex($list) {
    $script:apps = $list
    $script:keys = [string[]]@($list | ForEach-Object { $_.Key })
    $script:aliasArr = [string[]]@($list | ForEach-Object { $_.Aliases -join '|' })
    $script:hits = [int[]]@($list | ForEach-Object { [int]$script:hist[$_.Id] })
    $script:bonus = [int[]]@($list | ForEach-Object { [int]$kindBonus[$_.Kind] })
    $script:groups = [string[]]@($list | ForEach-Object { [string]$gameGroups[$_.Kind] })
    for ($i = 0; $i -lt $list.Count; $i++) { $list[$i] | Add-Member -NotePropertyName Idx -NotePropertyValue $i -Force }
}

# Reloads only if alias.txt or the shortcuts folder changed (the full list is refreshed in the background by the bar)
function Update-AppsIfStale {
    if ((Get-Item $aliasFile).LastWriteTime -ne $script:aliasStamp -or (Get-ShortcutStamp) -ne $script:shortcutStamp) { Import-Apps }
}

# Callers must wrap the result in @(...): with a single match PowerShell 5.1 returns the object alone, with no .Count
function Find-Apps([string]$text, [int]$max = 15) {
    $idx = [LauncherSearch]::Find($script:keys, $script:aliasArr, $script:hits, $script:bonus, $script:groups, $text, $max)
    @(foreach ($i in $idx) { $script:apps[$i] })
}

function Get-AppLabel($a) {
    if ($a.Aliases.Count) { return $a.Name + '    [' + ($a.Aliases -join ', ') + ']' }
    $a.Name
}

# ---- Launching ----

# Yes / No question, Yes being the default (Enter confirms)
function Confirm-Action([string]$title, [string]$question) {
    [Windows.Forms.MessageBox]::Show($question, $title, 'YesNo', 'Warning', 'Button1') -eq 'Yes'
}

# Asks first (Windows' own confirmation can be turned off), then empties the Recycle Bin
function Invoke-EmptyRecycleBin {
    $n = (New-Object -ComObject Shell.Application).Namespace(10).Items().Count
    if (-not $n) { [void][Windows.Forms.MessageBox]::Show('The Recycle Bin is already empty.', 'Recycle Bin', 'OK', 'Information'); return }
    if (-not (Confirm-Action 'Empty Recycle Bin' "Permanently delete $n item$(if ($n -gt 1) { 's' }) in the Recycle Bin?")) { return }
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
}

function Start-Entry($app) {
    if ($app.Shell) { $app.Shell.InvokeVerb() }                                                    # Control Panel item
    elseif ($app.Kind -eq 'Settings') { [void][Diagnostics.Process]::Start($app.Target) }          # ms-settings: page
    elseif ($app.Kind -eq 'Action') { & $actions[$app.Id].Run }                                    # built-in action
    elseif ($app.Kind -eq 'GOG') { Start-Process $app.Target -WorkingDirectory (Split-Path $app.Target) }   # games expect their own folder
    elseif ($app.Target) { Start-Process $app.Target }
    else { Start-Process explorer.exe "shell:AppsFolder\$($app.Id)" }                              # Start menu app
}

# Launches the entry (or, if $app is empty, the typed text: path, URL, command). Returns $true on success.
function Invoke-Launch($app, [string]$text) {
    $text = $text.Trim()
    $what = if ($app) { $app.Name } else { $text }
    try {
        if ($app) {
            Write-Log "Launch: $($app.Name) [$($app.Kind) $($app.Id)]"
            Start-Entry $app
            Add-LaunchCount $app
            return $true
        }
        if ($text) { Start-Process $text; return $true }
    } catch {
        Write-Log "Launch failed: $(if ($app) { "$($app.Name) [$($app.Id)]" } else { $text }): $($_.Exception.Message)"
        [void][Windows.Forms.MessageBox]::Show("Couldn't launch: $what", 'Wink')
    }
    $false
}

# The bar loads the list once it's on screen ($deferAppList); anything else (tests) gets it right away
if ($deferAppList) { Set-SearchIndex @() } else { Import-Apps }
