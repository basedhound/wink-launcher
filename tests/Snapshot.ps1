# Prints what the launcher finds on this PC: entries by kind, alias targets and the results of many searches.
# Run it before and after a change to the search or the app list: the two outputs should be identical
# (unless the change is meant to alter them).
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Snapshot.ps1 > before.txt
param([string]$Core)

$root = Split-Path $PSScriptRoot
if (-not $Core) { $Core = Join-Path $root 'src\Catalog.ps1' }
function Write-Log([string]$m) {}   # the bar's log isn't needed here
. $Core

'== Entries by kind'
$script:apps | Group-Object Kind | Sort-Object Name | ForEach-Object { '{0,-14} {1}' -f $_.Name, $_.Count }

'== Aliases'
$script:apps | Where-Object { $_.Aliases.Count } | Sort-Object { $_.Aliases[0] } |
    ForEach-Object { '{0,-8} -> {1} [{2}]' -f ($_.Aliases -join ','), $_.Name, $_.Kind }

'== Searches'
$queries = 'e', 'se', 'ex', 'ntpd', 'vsc', 'wifi', 'remove', 'uninst', 'power', 'index', 'update', 'mouse', 'hidden files',
    'calc', 'c', 'w', 'q', 'del', 'empty', 'erb', 'recy', 'google cal', 'gc', 'cal', 'mus', 'jsm', 'torrent',
    'steam', 'steam ', 'steam dark', 'steam ds', 'steam e', 'gog ', 'gog stranger', 'dark', 'zzzz', "cr$([char]0xE8)me", 'Display', 'x=excel'
foreach ($q in $queries) {
    "-- '$q'"
    foreach ($a in @(Find-Apps $q 12)) { '   {0} [{1}]' -f $a.Name, $a.Kind }
}
