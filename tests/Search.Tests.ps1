# Unit tests for the search engine (src\Search.cs), on made-up names: they pass or fail the same way on any PC.
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\Search.Tests.ps1
$root = Split-Path $PSScriptRoot
Add-Type -Path (Join-Path $root 'src\Search.cs')

$script:failed = 0
function Assert-Equal($expected, $actual, [string]$what) {
    if ("$expected" -ceq "$actual") { "  ok    $what" }
    else { "  FAIL  $what`n        expected: $expected`n        got:      $actual"; $script:failed++ }
}

# A small catalog: name, aliases, launches, kind bonus, group
$entries = @(
    @('Notepad', '', 0, 0, ''), @('Excel', 'x', 0, 0, ''), @('Exceed Share', '', 0, 0, ''),
    @('Visual Studio Code', '', 0, 0, ''), @('VLC media player', '', 0, 0, ''), @('YouTube Playlist', '', 0, 0, ''),
    @('Wi-Fi', '', 0, -50, ''), @('Display', '', 0, -50, ''), @('Windows Administrative Tools', '', 0, 0, ''),
    @('Calculator', 'calc|c', 0, 0, ''), @('Calibre', '', 5, 0, ''), @("Cr$([char]0xE8)me Studio", '', 0, 0, ''),
    @('ELDEN RING', '', 0, 0, 'steam'), @('DARK SOULS III', 'ds', 0, 0, 'steam'), @('Dark Souls Remastered', '', 0, 0, 'steam'),
    @('Stranger Things 3', '', 0, 0, 'gog')
)
$keys    = [string[]]@($entries | ForEach-Object { [LauncherSearch]::Key($_[0]) })
$aliases = [string[]]@($entries | ForEach-Object { $_[1] })
$hits    = [int[]]@($entries | ForEach-Object { $_[2] })
$bonus   = [int[]]@($entries | ForEach-Object { $_[3] })
$groups  = [string[]]@($entries | ForEach-Object { $_[4] })
function Find([string]$text, [int]$max = 5) {
    (@([LauncherSearch]::Find($keys, $aliases, $hits, $bonus, $groups, $text, $max)) | ForEach-Object { $entries[$_][0] }) -join ', '
}

'Key'
Assert-Equal 'creme studio' ([LauncherSearch]::Key("Cr$([char]0xE8)me Studio")) 'lower case, accents removed'

'Matching'
Assert-Equal 'Notepad' (Find 'ntpd' 1) 'letters in order from the start of a word'
Assert-Equal 'Visual Studio Code' (Find 'vsc' 1) 'initials'
Assert-Equal 'Wi-Fi' (Find 'wifi' 1) 'ignores separators'
Assert-Equal 'YouTube Playlist, VLC media player' (Find 'pla' 2) 'earlier word ranks first'
Assert-Equal '' (Find 'sarv') 'letters scattered across a long name do not match'
Assert-Equal "Cr$([char]0xE8)me Studio" (Find 'creme' 1) 'accents ignored'

'Ranking'
Assert-Equal 'Excel, Exceed Share' (Find 'exc' 2) 'shorter name first on equal score'
Assert-Equal 'Calibre, Calculator' (Find 'cal' 2) 'frequently launched first'
Assert-Equal 'Calculator' (Find 'c' 1) 'exact alias beats everything'
Assert-Equal 'Excel' (Find 'x' 1) 'alias'
Assert-Equal 'Display' (Find 'display' 1) 'Settings pages found despite their lower rank'

'Games (behind a prefix)'
Assert-Equal 'DARK SOULS III, Dark Souls Remastered' (Find 'steam dark') 'prefix searches the group (shorter name first)'
Assert-Equal '' (Find 'dark') 'games stay out of normal results'
Assert-Equal 'DARK SOULS III' (Find 'ds' 1) 'a game answers to its alias without the prefix'
Assert-Equal 'DARK SOULS III, Dark Souls Remastered, ELDEN RING' (Find 'steam ' 10) 'prefix alone lists the group alphabetically'
Assert-Equal 'Stranger Things 3' (Find 'gog str') 'other groups too'
Assert-Equal '' (Find 'steam') 'the prefix word alone is a normal search'

''
if ($script:failed) { "$script:failed test(s) failed"; exit 1 } else { 'All tests passed' }
