# Keeps the app list up to date: a program or game installed or uninstalled shows up a few seconds later.
# Every source of change (Start menu, Steam, GOG) only asks for a reload; one shared timer waits a few
# seconds (an installer writes several files), never reloads while you type, and reloads once.

function Update-AppList { Import-Apps; Start-IconPreload }   # icon cache kept: only new entries get loaded

$script:reloadRequests = @{}   # reason -> condition (scriptblock: reload only if it returns true; $null: always)
$reloadTimer = New-Object Windows.Forms.Timer
$reloadTimer.Interval = 3000

function Request-Reload([string]$reason, [scriptblock]$onlyIf) {
    $script:reloadRequests[$reason] = $onlyIf
    $reloadTimer.Stop(); $reloadTimer.Start()
}

$reloadTimer.Add_Tick({
    if (Test-Typing) { return }   # try again at the next tick
    $reloadTimer.Stop()
    $why = @($script:reloadRequests.GetEnumerator() | Where-Object { -not $_.Value -or (& $_.Value) } | ForEach-Object { $_.Key })
    $script:reloadRequests = @{}
    if ($why.Count) { Write-Log "$($why -join ', '): reloading apps"; Update-AppList }
})

# Calls $onEvent (on the bar's thread) whenever a file matching $filter is created, deleted or renamed in $dir
# (also changed, with -Changes; subfolders too, with -Recurse)
function Watch-Folder([string]$dir, [string]$filter, [scriptblock]$onEvent, [switch]$Recurse, [switch]$Changes) {
    if (-not (Test-Path -LiteralPath $dir)) { return }
    $w = New-Object IO.FileSystemWatcher $dir, $filter
    $w.IncludeSubdirectories = [bool]$Recurse
    $w.NotifyFilter = if ($Changes) { [IO.NotifyFilters]'FileName, LastWrite' } else { [IO.NotifyFilters]'FileName, DirectoryName' }
    $w.SynchronizingObject = $bar   # events arrive on the UI thread
    $w.Add_Created($onEvent); $w.Add_Deleted($onEvent); $w.Add_Renamed($onEvent)
    if ($Changes) { $w.Add_Changed($onEvent) }
    $w.EnableRaisingEvents = $true
    $w
}

# Start menu: Windows tells us when a shortcut is added or removed (any program's installer).
# Windows' own app list can take a few more seconds to follow (mostly after an uninstall): looked at again
# 15 seconds later, reloaded again only if it changed meanwhile.
$startMenuRecheck = New-Object Windows.Forms.Timer
$startMenuRecheck.Interval = 15000
$startMenuRecheck.Add_Tick({
    $startMenuRecheck.Stop()
    Request-Reload 'Start menu changed' { (Get-StartMenuStamp) -ne $script:startStamp }
})
$onStartMenu = { Request-Reload 'Start menu changed'; $startMenuRecheck.Stop(); $startMenuRecheck.Start() }
$script:watchers = @(foreach ($d in [Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms')) {
    Watch-Folder $d '*.*' $onStartMenu -Recurse
})

# Steam: a game's appmanifest file appears, changes or disappears in a library folder. Steam rewrites
# these files during downloads too, so the list only reloads if the set of installed games changed.
$onSteam = { Request-Reload 'Steam games changed' { (Get-SteamStamp) -ne $script:steamStamp } }
$script:watchers += @(foreach ($d in @(Get-SteamLibraries)) { Watch-Folder $d 'appmanifest_*.acf' $onSteam -Changes })

# GOG games live in the registry (no file to watch): a quick look every 5 seconds (about 1 ms)
$gogTimer = New-Object Windows.Forms.Timer
$gogTimer.Interval = 5000
$gogTimer.Add_Tick({
    if (-not (Test-Typing) -and (Get-GogStamp) -ne $script:gogStamp) { Request-Reload 'GOG games changed' { (Get-GogStamp) -ne $script:gogStamp } }
})

# Everything else (Microsoft Store apps...): a full refresh every 30 minutes, when the bar isn't in use
$refreshTimer = New-Object Windows.Forms.Timer
$refreshTimer.Interval = 30 * 60 * 1000
$refreshTimer.Add_Tick({ if (-not $box.Focused) { Update-AppList } })
