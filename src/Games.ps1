# Installed games (Steam, GOG). They stay out of the normal results: searched only after their prefix
# ("steam dark", "gog "), or through an alias.

# Kind of entry -> search prefix
$gameGroups = @{ 'Steam' = 'steam'; 'GOG' = 'gog' }

# ---- Steam ----

function Get-SteamPath {
    $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($p) { $p -replace '/', '\' }
}

# Every Steam library's steamapps folder (other drives included)
function Get-SteamLibraries {
    $steam = Get-SteamPath
    if (-not $steam) { return }
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        $text = Get-Content -LiteralPath $vdf -Raw -Encoding UTF8
        $libs += [regex]::Matches($text, '"path"\s+"([^"]+)"') | ForEach-Object { $_.Groups[1].Value -replace '\\\\', '\' }
    }
    $libs | ForEach-Object { Join-Path $_ 'steamapps' } | Where-Object { Test-Path -LiteralPath $_ } | Sort-Object -Unique
}

# One appmanifest file -> @{ Id; Name } if it's a fully installed game (not one of Steam's own runtimes)
function Read-SteamManifest([string]$path) {
    $t = Get-Content -LiteralPath $path -Raw -Encoding UTF8
    $id = [regex]::Match($t, '"appid"\s+"(\d+)"').Groups[1].Value
    $name = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value
    $flags = [int][regex]::Match($t, '"StateFlags"\s+"(\d+)"').Groups[1].Value
    $installed = ($flags -band 4) -ne 0
    if ($id -and $name -and $installed -and $name -notmatch '^(Steamworks|Proton|Steam Linux Runtime)') { @{ Id = $id; Name = $name } }
}

# Installed Steam games: appid -> name
function Get-SteamInstalled {
    $res = [ordered]@{}
    foreach ($dir in Get-SteamLibraries) {
        foreach ($f in Get-ChildItem -LiteralPath $dir -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue) {
            $game = Read-SteamManifest $f.FullName
            if ($game -and -not $res.Contains($game.Id)) { $res[$game.Id] = $game.Name }
        }
    }
    $res
}

# Steam keeps each game's small icon as a 32x32 jpg named by its hash (fallback: Steam's own icon)
function Get-SteamIcon([string]$steam, [string]$id) {
    $icon = Get-ChildItem -LiteralPath (Join-Path $steam "appcache\librarycache\$id") -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9a-f]{40}\.jpg$' } | Select-Object -First 1
    if ($icon) { $icon.FullName } else { Join-Path $steam 'steam.exe' }
}

# Changes when a Steam game is installed or uninstalled (cheap: used to decide whether to reload)
function Get-SteamStamp { (Get-SteamInstalled).Keys -join ',' }

# ---- GOG ----

# Installed GOG games: listed in the registry by their installer (only those whose game file is there).
# Read through .NET: about 1 ms, against ~30 ms with Get-ItemProperty (checked every few seconds).
function Get-GogInstalled {
    foreach ($root in 'SOFTWARE\WOW6432Node\GOG.com\Games', 'SOFTWARE\GOG.com\Games') {
        $k = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($root)
        if (-not $k) { continue }
        foreach ($n in $k.GetSubKeyNames()) {
            $g = $k.OpenSubKey($n)
            if (-not $g) { continue }
            $name = $g.GetValue('gameName'); $exe = $g.GetValue('exe'); $id = $g.GetValue('gameID')
            $g.Close()
            if ($name -and $exe -and [IO.File]::Exists($exe)) {
                [pscustomobject]@{ gameName = $name; gameID = $(if ($id) { $id } else { $n }); exe = $exe }
            }
        }
        $k.Close()
    }
}

# Changes when a GOG game is installed or uninstalled
function Get-GogStamp { (@(Get-GogInstalled) | ForEach-Object { $_.gameID }) -join ',' }

# ---- Entries for the search ----

function Get-GameEntries {
    $steam = Get-SteamPath
    $installed = Get-SteamInstalled
    foreach ($id in $installed.Keys) {
        New-Entry $installed[$id] "steam:$id" 'Steam' "steam://rungameid/$id" (Get-SteamIcon $steam $id)
    }
    Get-GogInstalled | ForEach-Object { New-Entry $_.gameName "gog:$($_.gameID)" 'GOG' $_.exe }
}
