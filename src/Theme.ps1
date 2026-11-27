# Colours and sizes shared by the bar, the suggestion list and the alias window (dark theme)

# Screen scaling (1 at 100 %, 1.25 at 125 %...): every size below is given at 100 % and multiplied by it
$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96; $g.Dispose()
function px([double]$v) { [int]($v * $scale) }

function New-Color([int]$r, [int]$g, [int]$b) { [Drawing.Color]::FromArgb($r, $g, $b) }
$theme = @{
    Bar        = New-Color 45 45 45       # the search box; also input fields and buttons in the alias window
    BarHover   = New-Color 58 58 58
    Popup      = New-Color 32 32 32       # suggestion list and alias window background
    Selection  = New-Color 60 90 140      # selected suggestion; the alias window's main button
    AccentHover = New-Color 76 110 166
    Line       = New-Color 52 52 52
    RowSelect  = New-Color 42 46 54       # selected alias row
    Text       = New-Color 232 232 232
    Muted      = New-Color 150 150 150
    Alias      = New-Color 140 180 245
    Delete     = New-Color 232 80 90
    Thumb      = New-Color 95 98 108      # scrollbar of the suggestion list
    ThumbHover = New-Color 140 144 156
}

# Rounded rectangle path (corner radius r)
function New-RoundedPath([int]$w, [int]$h, [int]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $p.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $p.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90); $p.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $p.CloseFigure()
    $p
}
