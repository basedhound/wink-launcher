# Icons of the entries, loaded once and cached (by entry, and by file for icons many entries share)

$script:icons = @{}        # entry Id -> image
$script:iconByPath = @{}   # icon source -> image (all Settings pages share one icon, for example)
$iconPx = px 32
$script:msiIcons = @{}     # Start menu app name -> its .ico, for the icons Windows shows broken (see Update-MsiIcons)

# Apps installed by an MSI installer can have a Start menu icon Windows can't show (a generic picture icon):
# their real .ico is read directly instead. Refreshed with the app list.
function Update-MsiIcons {
    $dirs = [string[]]@([Environment]::GetFolderPath('CommonPrograms'), [Environment]::GetFolderPath('Programs'))
    try { $script:msiIcons = [LauncherIcon]::MsiShortcutIcons($dirs) } catch { Write-Log "MSI icons: $_" }
}

# Where an entry's icon comes from: its own icon path, its file (or the program a command runs),
# or the Start menu app itself
function Get-IconSource($a) {
    if ($a.IconPath) { return $a.IconPath }   # Control Panel, Settings, actions, games
    if (-not $a.Target) {
        if ($script:msiIcons.ContainsKey($a.Name)) { return "$($script:msiIcons[$a.Name]),0" }
        return "shell:AppsFolder\$($a.Id)"
    }
    $t = [Environment]::ExpandEnvironmentVariables($a.Target)
    if (Test-Path -LiteralPath $t -ErrorAction SilentlyContinue) { return (Resolve-Path -LiteralPath $t).Path }
    $cmd = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { $cmd.Source }
}

function Read-Icon([string]$path) {
    if ($path -match '\.(jpg|png)$') { return [LauncherIcon]::FromPicture($path, $iconPx) }   # Steam game pictures
    if ($path -match '^(.+\.(?:dll|ico)),(-?\d+)$') { return [LauncherIcon]::FromResource($Matches[1], [int]$Matches[2], $iconPx) }   # built-in actions, MSI apps
    [LauncherIcon]::Get($path, $iconPx)
}

function Get-AppIcon($a) {
    if (-not $a) { return $null }
    if ($script:icons.ContainsKey($a.Id)) { return $script:icons[$a.Id] }
    $img = $null
    $path = Get-IconSource $a
    if ($path) {
        if (-not $script:iconByPath.ContainsKey($path)) { $script:iconByPath[$path] = Read-Icon $path }
        $img = $script:iconByPath[$path]
    }
    $script:icons[$a.Id] = $img
    $img
}

# Icons cost ~25 ms each the first time: preload them all in the background (most used apps first),
# a couple per tick and never while typing, so suggestions always show up instantly.
$script:iconQueue = New-Object Collections.Queue
$preload = New-Object Windows.Forms.Timer
$preload.Interval = 20
$preload.Add_Tick({
    if (Test-Typing) { return }
    for ($n = 0; $n -lt 2 -and $script:iconQueue.Count; $n++) { [void](Get-AppIcon $script:iconQueue.Dequeue()) }
    if (-not $script:iconQueue.Count) { $preload.Stop() }
})

function Start-IconPreload {
    Update-MsiIcons
    $script:iconQueue.Clear()
    foreach ($a in ($script:apps | Sort-Object { -[int]$script:hist[$_.Id] })) {
        if (-not $script:icons.ContainsKey($a.Id)) { $script:iconQueue.Enqueue($a) }
    }
    if ($script:iconQueue.Count) { $preload.Start() }
}
