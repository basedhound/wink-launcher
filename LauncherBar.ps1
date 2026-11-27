# Search bar that sits inside the Windows taskbar.
# Click it (or tap the Windows key), type, press Enter to launch.

# ---- Settings (in "logical" pixels, at 100 % scaling) ----
$Width       = 110     # width of the search bar
$RightMargin = 290     # only used if the clock / tray area can't be found
$WindowsKey  = $true   # tap the Windows key alone to open the bar (instead of the Start menu)
$HideStartButton = $true   # hide the taskbar's Start button (Ctrl+Esc still opens the Start menu)
# ----------------------------------------------------------

# Single instance
$mutex = New-Object Threading.Mutex($false, 'Local\LauncherBar')
if (-not $mutex.WaitOne(0)) { exit }

# If the bar was quit on purpose, the auto-restart task doesn't reopen it until the next reboot
$stopFlag = Join-Path $env:APPDATA 'Launcher\stopped'
if (Test-Path $stopFlag) {
    $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
    if ((Get-Item $stopFlag).LastWriteTime -gt $boot) { exit }
    Remove-Item $stopFlag -Force -ErrorAction SilentlyContinue
}

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;
// Suggestions window that shows up WITHOUT taking the keyboard (otherwise you can't keep typing)
public class LauncherPopup : Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override CreateParams CreateParams {
        get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; return cp; } // NOACTIVATE | TOOLWINDOW | TOPMOST
    }
    // Clicking a suggestion must not activate this window: WinForms would otherwise activate it,
    // the bar would get Deactivate (which clears it and hides this list) before the click lands.
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x0021) { m.Result = new IntPtr(3); return; }   // WM_MOUSEACTIVATE -> MA_NOACTIVATE
        base.WndProc(ref m);
    }
}
// Dark right-click menus (same colours as the bar and the alias manager)
public class DarkMenuColors : ProfessionalColorTable {
    static readonly Color Bg = Color.FromArgb(43, 43, 43), Hover = Color.FromArgb(62, 62, 62), Line = Color.FromArgb(70, 70, 70);
    public override Color ToolStripDropDownBackground { get { return Bg; } }
    public override Color ImageMarginGradientBegin { get { return Bg; } }
    public override Color ImageMarginGradientMiddle { get { return Bg; } }
    public override Color ImageMarginGradientEnd { get { return Bg; } }
    public override Color MenuBorder { get { return Line; } }
    public override Color MenuItemBorder { get { return Hover; } }
    public override Color MenuItemSelected { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
    public override Color MenuItemPressedGradientBegin { get { return Hover; } }
    public override Color MenuItemPressedGradientEnd { get { return Hover; } }
    public override Color CheckBackground { get { return Bg; } }
    public override Color CheckSelectedBackground { get { return Hover; } }
    public override Color CheckPressedBackground { get { return Hover; } }
    public override Color SeparatorDark { get { return Line; } }
    public override Color SeparatorLight { get { return Bg; } }
}
public class DarkMenuRenderer : ToolStripProfessionalRenderer {
    static readonly Color Text = Color.FromArgb(235, 235, 235), Line = Color.FromArgb(70, 70, 70);
    public DarkMenuRenderer() : base(new DarkMenuColors()) { RoundedEdges = false; }
    static readonly Color Hover = Color.FromArgb(62, 62, 62);
    // Highlight over the item's full height (the default one is 1 px short at the bottom)
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        if (!e.Item.Selected || !e.Item.Enabled) return;
        using (var b = new SolidBrush(Hover)) e.Graphics.FillRectangle(b, 3, 0, e.Item.Width - 6, e.Item.Height);
    }
    // Text centred on the item's full height (the default text box sits a few pixels too high)
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        var r = new Rectangle(e.TextRectangle.X, 0, e.TextRectangle.Width, e.Item.Height);
        TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, r, e.Item.Enabled ? Text : Color.Gray,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix);
    }
    // Light check mark, drawn by hand (the default one is black)
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        var r = e.ImageRectangle; var g = e.Graphics;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using (var p = new Pen(Text, Math.Max(1.5f, r.Height / 9f)))
            g.DrawLines(p, new[] { new PointF(r.Left + r.Width * 0.22f, r.Top + r.Height * 0.52f),
                                   new PointF(r.Left + r.Width * 0.42f, r.Top + r.Height * 0.72f),
                                   new PointF(r.Left + r.Width * 0.80f, r.Top + r.Height * 0.30f) });
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        var r = e.Item.ContentRectangle; int y = r.Top + r.Height / 2;
        using (var p = new Pen(Line)) e.Graphics.DrawLine(p, r.Left + 6, y, r.Right - 6, y);
    }
}
public class LauncherNative : NativeWindow {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string c, string t);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    public event EventHandler HotKey;
    public LauncherNative() { CreateHandle(new CreateParams()); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x8001 && HotKey != null) HotKey(this, EventArgs.Empty);   // Windows key tapped (WM_APP+1, posted by the hook)
        base.WndProc(ref m);
    }
    // ---- Windows key alone: opens the bar instead of the Start menu ----
    // Low-level keyboard hook on its own thread (typing never lags, even when the bar is busy).
    // Win+E, Win+D... keep working: we only react when the Windows key is released with no other key in between.
    delegate IntPtr LLProc(int n, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential)] struct KBD { public uint vk, scan, flags, time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr h; public uint msg; public IntPtr w, l; public uint time; public int x, y; }
    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LLProc fn, IntPtr mod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG m, IntPtr h, uint a, uint b);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr h, int msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    LLProc proc; IntPtr hook, target; bool winDown, other;
    public void StartWinKey() {
        target = Handle; proc = HookProc;
        var t = new System.Threading.Thread(() => {
            hook = SetWindowsHookEx(13, proc, GetModuleHandle(null), 0);   // WH_KEYBOARD_LL
            MSG m; while (GetMessage(out m, IntPtr.Zero, 0, 0) > 0) { }
        });
        t.IsBackground = true; t.Start();
    }
    IntPtr HookProc(int n, IntPtr w, IntPtr l) {
        if (n >= 0) {
            var k = (KBD)Marshal.PtrToStructure(l, typeof(KBD));
            if ((k.flags & 0x10) == 0) {   // ignore simulated keys (our own)
                int msg = w.ToInt32();
                bool down = msg == 0x100 || msg == 0x104, up = msg == 0x101 || msg == 0x105;
                if (k.vk == 0x5B || k.vk == 0x5C) {   // left / right Windows key
                    if (down) { if (!winDown) { winDown = true; other = false; } }
                    else if (up && winDown) {
                        winDown = false;
                        if (!other) {
                            // A "silent" key between press and release: Windows doesn't open the Start menu
                            keybd_event(0xE8, 0, 0, UIntPtr.Zero); keybd_event(0xE8, 0, 2, UIntPtr.Zero);
                            keybd_event((byte)k.vk, 0, 1 | 2, UIntPtr.Zero);   // Windows key release (simulated)
                            PostMessage(target, 0x8001, IntPtr.Zero, IntPtr.Zero);
                            return new IntPtr(1);   // the real release is swallowed
                        }
                    }
                } else if (down && winDown) other = true;
            }
        }
        return CallNextHookEx(hook, n, w, l);
    }
    public static void KeepOnTop(IntPtr h) { SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010); }
    // Brings the window to the front, even when another app has the keyboard
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool f);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    public static void Front(IntPtr h) {
        uint pid, ft = GetWindowThreadProcessId(GetForegroundWindow(), out pid), me = GetCurrentThreadId();
        if (ft != 0 && ft != me) { AttachThreadInput(me, ft, true); SetForegroundWindow(h); AttachThreadInput(me, ft, false); }
        else SetForegroundWindow(h);
    }
    // Last window used outside the bar (to give the keyboard back on Esc)
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    public static IntPtr OtherForeground() {
        IntPtr f = GetForegroundWindow(); uint pid; GetWindowThreadProcessId(f, out pid);
        return (f == IntPtr.Zero || pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) ? IntPtr.Zero : f;
    }
    public static bool Alive(IntPtr h) { return h != IntPtr.Zero && IsWindow(h); }
    public static void Placeholder(IntPtr box, string text) { SendMessage(box, 0x1501, new IntPtr(1), text); }
    // Taskbar rectangle (empty if not found)
    public static Rectangle Taskbar() {
        IntPtr t = FindWindow("Shell_TrayWnd", null); RECT r;
        if (t == IntPtr.Zero || !GetWindowRect(t, out r)) return Rectangle.Empty;
        return Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
    }
    // Ties the window to the taskbar: an "owned" window always stays above its owner,
    // even when the Start menu brings the taskbar back to the front.
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    public static void AttachToTaskbar(IntPtr h) {
        IntPtr t = FindWindow("Shell_TrayWnd", null);
        if (t != IntPtr.Zero && GetWindowLongPtr(h, -8) != t) SetWindowLongPtr(h, -8, t);   // GWLP_HWNDPARENT
    }
    // Is a window (movie, game, slideshow...) full screen on the primary display?
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public static bool FullscreenApp() {
        IntPtr f = GetForegroundWindow(); if (f == IntPtr.Zero) return false;
        uint pid; GetWindowThreadProcessId(f, out pid);
        if (pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) return false;
        var cls = new System.Text.StringBuilder(64); GetClassName(f, cls, 64);
        string c = cls.ToString();
        if (c == "Progman" || c == "WorkerW" || c == "Shell_TrayWnd" || c == "Shell_SecondaryTrayWnd" || c == "Windows.UI.Core.CoreWindow") return false;
        RECT r; if (!GetWindowRect(f, out r)) return false;
        var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(MonitorFromWindow(f, 2), ref mi) || (mi.dwFlags & 1) == 0) return false;   // primary display only
        return r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B;
    }
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    public static void Hide(IntPtr h) { ShowWindow(h, 0); }
    public static void ShowNoActivate(IntPtr h) { ShowWindow(h, 4); }
    // Dark title bar (Windows 10 20H1+ / 11; attribute 19 on older 10 builds) and dark scrollbars
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);
    public static void DarkTitle(IntPtr h) { int on = 1; if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); }
    public static void DarkScroll(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }
    // Shows / hides the taskbar's Start button (the Start menu itself still opens with Ctrl+Esc).
    // Explorer may show it again (taskbar rebuilt, Explorer restarted), so this is called from the bar's timer.
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    // reserve: pixels kept free at the taskbar's left edge (the bar itself, when it sits on the left), 0 otherwise.
    // Explorer puts the app area back next to the (hidden) Start button whenever it re-lays out the taskbar
    // (opening "Show hidden icons", an app opening...). The 500 ms timer would leave the pinned apps under
    // the bar for a moment, so a WinEvent hook watches the app area and moves it back as soon as it moves.
    delegate void WinEventProc(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr mod, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr h);
    static WinEventProc moveProc;   // kept referenced so it isn't garbage collected
    static IntPtr moveHook, moveRebar;
    static bool lastVisible = true; static int lastReserve;
    static void OnMove(IntPtr hook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
        if (hwnd == moveRebar && idObject == 0 && !lastVisible) StartButton(false, lastReserve);
    }
    static void WatchRebar(IntPtr rebar) {
        if (rebar == moveRebar && moveHook != IntPtr.Zero) return;
        if (moveHook != IntPtr.Zero) { UnhookWinEvent(moveHook); moveHook = IntPtr.Zero; }
        moveRebar = rebar; if (rebar == IntPtr.Zero) return;
        uint pid; GetWindowThreadProcessId(rebar, out pid);
        if (moveProc == null) moveProc = OnMove;
        moveHook = SetWinEventHook(0x800B, 0x800B, IntPtr.Zero, moveProc, pid, 0, 0);   // EVENT_OBJECT_LOCATIONCHANGE, out of context
    }
    public static void StartButton(bool visible, int reserve) {
        lastVisible = visible; lastReserve = reserve;
        IntPtr t = FindWindow("Shell_TrayWnd", null); if (t == IntPtr.Zero) return;
        IntPtr s = FindWindowEx(t, IntPtr.Zero, "Start", null); if (s == IntPtr.Zero) return;
        if (IsWindowVisible(s) != visible) ShowWindow(s, visible ? 5 : 0);   // SW_SHOW / SW_HIDE
        // Slide the app area (pinned / open apps) into the Start button's spot (or after the bar), or back next to the button.
        // Horizontal taskbar only.
        RECT tr, sr, br;
        IntPtr b = FindWindowEx(t, IntPtr.Zero, "ReBarWindow32", null);
        WatchRebar(visible ? IntPtr.Zero : b);
        if (b == IntPtr.Zero || !GetWindowRect(t, out tr) || !GetWindowRect(s, out sr) || !GetWindowRect(b, out br)) return;
        if (tr.R - tr.L < tr.B - tr.T) return;
        int left = visible ? sr.R : (reserve > 0 ? tr.L + reserve : sr.L);
        if (br.L != left && br.R > left)
            SetWindowPos(b, IntPtr.Zero, left - tr.L, br.T - tr.T, br.R - left, br.B - br.T, 0x0004 | 0x0010);   // NOZORDER | NOACTIVATE
    }
    // Left edge of the clock / system icons area (0 if not found)
    public static int TrayLeft() {
        IntPtr t = FindWindow("Shell_TrayWnd", null); if (t == IntPtr.Zero) return 0;
        IntPtr n = FindWindowEx(t, IntPtr.Zero, "TrayNotifyWnd", null); RECT r;
        if (n == IntPtr.Zero || !GetWindowRect(n, out r)) return 0;
        return r.L;
    }
}
// Icon of an app (Start menu app, file or folder), with transparency
[ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IShellItemImageFactory { [PreserveSig] int GetImage(SIZE size, int flags, out IntPtr phbm); }
[StructLayout(LayoutKind.Sequential)] struct SIZE { public int cx, cy; }
public static class LauncherIcon {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr pbc, [MarshalAs(UnmanagedType.LPStruct)] Guid riid, [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory ppv);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
    public static Bitmap Get(string path, int size) {
        IntPtr hb = IntPtr.Zero;
        try {
            IShellItemImageFactory f;
            SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out f);
            if (f.GetImage(new SIZE { cx = size, cy = size }, 0x4, out hb) != 0) return null;   // SIIGBF_ICONONLY
            using (var src = Image.FromHbitmap(hb)) {
                if (Image.GetPixelFormatSize(src.PixelFormat) < 32) return new Bitmap(src);
                var d = src.LockBits(new Rectangle(0, 0, src.Width, src.Height), ImageLockMode.ReadOnly, src.PixelFormat);
                try { using (var argb = new Bitmap(d.Width, d.Height, d.Stride, PixelFormat.Format32bppArgb, d.Scan0)) return new Bitmap(argb); }
                finally { src.UnlockBits(d); }
            }
        } catch { return null; }
        finally { if (hb != IntPtr.Zero) DeleteObject(hb); }
    }
}
'@
[void][LauncherNative]::SetProcessDPIAware()
[System.Windows.Forms.Application]::EnableVisualStyles()

# Log (start, stop, errors) in %APPDATA%\Launcher\bar.log
$logFile = Join-Path $env:APPDATA 'Launcher\bar.log'
New-Item -ItemType Directory -Force (Split-Path $logFile) | Out-Null
function Write-Log([string]$m) {
    try {
        if ((Test-Path $logFile) -and (Get-Item $logFile).Length -gt 200KB) { Remove-Item $logFile -Force }
        Add-Content -Path $logFile -Value ("{0:yyyy-MM-dd HH:mm:ss}  {1}" -f (Get-Date), $m) -Encoding UTF8
    } catch {}
}
Write-Log "Start (PID $PID)"
# An error in the bar must never close it: log it and carry on
[Windows.Forms.Application]::SetUnhandledExceptionMode('CatchException')
[Windows.Forms.Application]::add_ThreadException({ param($s, $e) Write-Log "Error: $($e.Exception.Message)" })

. (Join-Path $PSScriptRoot 'LauncherCore.ps1')

$g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $scale = $g.DpiX / 96; $g.Dispose()

# Side of the taskbar the bar sits on (right-click menu), saved in %APPDATA%\Launcher\settings.json.
# Top / bottom always follows the taskbar itself.
#   Right: next to the clock (default)   Left: in place of the Start button
$settingsFile = Join-Path $env:APPDATA 'Launcher\settings.json'
$script:side = 'Right'
try { if ((Get-Content $settingsFile -Raw -ErrorAction Stop | ConvertFrom-Json).Side -eq 'Left') { $script:side = 'Left' } } catch {}
function Set-Side([string]$s) {
    $script:side = $s
    try { @{ Side = $s } | ConvertTo-Json | Set-Content -Encoding UTF8 $settingsFile } catch {}
    Write-Log "Position: $s"
    Update-Layout; Update-StartButton
}

# Start button: hidden when the bar takes its place (left) or when $HideStartButton is on.
# Then the pinned / open apps slide left: into the button's spot, or just after the bar.
$script:startHidden = $false
function Update-StartButton {
    if ($script:side -eq 'Left') {
        [LauncherNative]::StartButton($false, $bar.Right - $script:tbLeft + [int](6 * $scale)); $script:startHidden = $true
    } elseif ($HideStartButton) {
        [LauncherNative]::StartButton($false, 0); $script:startHidden = $true
    } elseif ($script:startHidden) {
        [LauncherNative]::StartButton($true, 0); $script:startHidden = $false
    }
}
$bg     = [Drawing.Color]::FromArgb(45, 45, 45)
$bgPop  = [Drawing.Color]::FromArgb(32, 32, 32)
$selCol = [Drawing.Color]::FromArgb(60, 90, 140)
$brBg   = New-Object Drawing.SolidBrush($bgPop)
$brSel  = New-Object Drawing.SolidBrush($selCol)

# ---- Icons (cached) ----
$script:icons = @{}
$script:iconByPath = @{}
$iconPx = [int](32 * $scale)
function Get-AppIcon($a) {
    if (-not $a) { return $null }
    if ($script:icons.ContainsKey($a.Id)) { return $script:icons[$a.Id] }
    $path = $null
    if ($a.IconPath) { $path = $a.IconPath }   # Control Panel / Settings
    elseif ($a.Target) {
        $t = [Environment]::ExpandEnvironmentVariables($a.Target)
        if (Test-Path -LiteralPath $t -ErrorAction SilentlyContinue) { $path = (Resolve-Path -LiteralPath $t).Path }
        else { $cmd = Get-Command $t -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($cmd) { $path = $cmd.Source } }
    } else { $path = "shell:AppsFolder\$($a.Id)" }
    # Same icon file for many entries (Settings pages): extracted only once
    if ($path -and $script:iconByPath.ContainsKey($path)) { $img = $script:iconByPath[$path] }
    elseif ($path -match '\.(jpg|png)$') {
        # Picture used as an icon (Steam games): the shell would only give the generic picture-file icon
        $img = $null
        try {
            $src = New-Object Drawing.Bitmap (New-Object IO.MemoryStream (, [IO.File]::ReadAllBytes($path)))
            $img = New-Object Drawing.Bitmap $iconPx, $iconPx
            $g = [Drawing.Graphics]::FromImage($img); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($src, 0, 0, $iconPx, $iconPx); $g.Dispose(); $src.Dispose()
        } catch {}
        $script:iconByPath[$path] = $img
    }
    else { $img = if ($path) { [LauncherIcon]::Get($path, $iconPx) } else { $null }; if ($path) { $script:iconByPath[$path] = $img } }
    $script:icons[$a.Id] = $img
    $img
}

# Icons cost ~25 ms each the first time: preload them all in the background (most used apps first),
# a couple per tick and never while typing, so suggestions always show up instantly.
$script:iconQueue = New-Object Collections.Queue
$preload = New-Object Windows.Forms.Timer
$preload.Interval = 20
$preload.Add_Tick({
    if ($box.Focused -and $box.Text) { return }
    for ($n = 0; $n -lt 2 -and $script:iconQueue.Count; $n++) { [void](Get-AppIcon $script:iconQueue.Dequeue()) }
    if (-not $script:iconQueue.Count) { $preload.Stop() }
})
function Start-IconPreload {
    $script:iconQueue.Clear()
    foreach ($a in ($script:apps | Sort-Object { -[int]$script:hist[$_.Id] })) {
        if (-not $script:icons.ContainsKey($a.Id)) { $script:iconQueue.Enqueue($a) }
    }
    if ($script:iconQueue.Count) { $preload.Start() }
}

# Magnifier drawn once (bar icon when nothing is typed)
function New-Magnifier([int]$s) {
    $b = New-Object Drawing.Bitmap($s, $s)
    $gr = [Drawing.Graphics]::FromImage($b); $gr.SmoothingMode = 'AntiAlias'
    $pen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(200, 200, 200), [single]([Math]::Max(1.5, $s / 11)))
    $d = $s * 0.58; $o = $s * 0.08
    $gr.DrawEllipse($pen, [single]$o, [single]$o, [single]$d, [single]$d)
    $gr.DrawLine($pen, [single]($o + $d * 0.85), [single]($o + $d * 0.85), [single]($s * 0.92), [single]($s * 0.92))
    $gr.Dispose(); $b
}

# ---- The bar ----
$bar = New-Object Windows.Forms.Form
$bar.AutoScaleMode = 'None'
$bar.FormBorderStyle = 'None'
$bar.ShowInTaskbar = $false
$bar.StartPosition = 'Manual'
$bar.TopMost = $true
$bar.BackColor = $bg
$bar.MinimumSize = New-Object Drawing.Size(1, 1)

$pic = New-Object Windows.Forms.PictureBox
$pic.SizeMode = 'Zoom'
$pic.BackColor = $bg
$bar.Controls.Add($pic)

$box = New-Object Windows.Forms.TextBox
$box.BorderStyle = 'None'
$box.BackColor = $bg
$box.ForeColor = [Drawing.Color]::White
$box.Font = New-Object Drawing.Font('Segoe UI', 10)
$bar.Controls.Add($box)

$script:magnifier = $null
$script:lay = $null

# Places the bar in the taskbar, just left of the system icons / clock.
# Called continuously: re-aligns if the taskbar wasn't ready at startup, or if the screen changes.
function Update-Layout {
    # Height / vertical position: screen minus working area (stable). Handles the taskbar at the top OR the bottom.
    # The Shell_TrayWnd window itself sometimes grows (hidden icons menu, animations): only used as a last resort.
    $scr = [Windows.Forms.Screen]::PrimaryScreen.Bounds
    $wa  = [Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $atTop = $false
    if ($wa.Top -gt $scr.Top) { $atTop = $true; $hgt = $wa.Top - $scr.Top }
    elseif ($wa.Bottom -lt $scr.Bottom) { $hgt = $scr.Bottom - $wa.Bottom }
    else {
        # auto-hidden taskbar: look at where Shell_TrayWnd is
        $t = [LauncherNative]::Taskbar()
        $atTop = (-not $t.IsEmpty) -and ($t.Top -le $scr.Top + 2) -and ($t.Bottom -lt $scr.Bottom - 2)
        $hgt = if (-not $t.IsEmpty) { $t.Height } else { 0 }
    }
    if ($hgt -lt 20 -or $hgt -gt 120 * $scale) { $hgt = [int](40 * $scale) }   # not ready yet
    $tbY = if ($atTop) { $scr.Top } else { $scr.Bottom - $hgt }
    $tb = New-Object Drawing.Rectangle($scr.Left, $tbY, $scr.Width, $hgt)
    $script:tbAtTop = $atTop; $script:tbBottom = $tb.Bottom
    $w = [int]($Width * $scale)
    $h = [int]([Math]::Min($tb.Height * 0.66, 36 * $scale))
    $script:tbLeft = $tb.Left
    if ($script:side -eq 'Left') {
        $x = $tb.Left + [int](6 * $scale)   # where the Start button was
    } else {
        $right = [LauncherNative]::TrayLeft()
        if ($right -le $tb.Left + $w -or $right -gt $tb.Right) { $right = $tb.Right - [int]($RightMargin * $scale) }
        $x = $right - $w - [int](8 * $scale)
    }
    $y = $tb.Top + [int](($tb.Height - $h) / 2)
    $want = New-Object Drawing.Rectangle($x, $y, $w, $h)
    $key = "$x,$y,$w,$h,$($tb.Top)"
    if ($key -eq $script:lay) {
        # Windows sometimes moves the window by itself (into the working area): put it back
        if (-not $bar.Bounds.Equals($want)) { $bar.Bounds = $want; Write-Log "Repositioned (Windows had moved it)" }
        return
    }
    $script:lay = $key
    $script:tbTop = $tb.Top; $script:barX = $x
    $bar.Bounds = $want
    # rounded corners
    $r = [int](8 * $scale); $p = New-Object Drawing.Drawing2D.GraphicsPath
    $p.AddArc(0, 0, $r * 2, $r * 2, 180, 90); $p.AddArc($w - $r * 2, 0, $r * 2, $r * 2, 270, 90)
    $p.AddArc($w - $r * 2, $h - $r * 2, $r * 2, $r * 2, 0, 90); $p.AddArc(0, $h - $r * 2, $r * 2, $r * 2, 90, 90)
    $p.CloseFigure(); $bar.Region = New-Object Drawing.Region($p)
    # icon on the left, text on the right
    $is = [int]($h * 0.58)
    $pic.Bounds = New-Object Drawing.Rectangle([int](8 * $scale), [int](($h - $is) / 2), $is, $is)
    $script:magnifier = New-Magnifier $is
    if (-not $box.Text) { $pic.Image = $script:magnifier }
    $bx = $pic.Right + [int](6 * $scale)
    $box.Left = $bx
    $box.Width = $w - $bx - [int](8 * $scale)
    $box.Top = [int](($h - $box.Height) / 2)
}

$bar.Add_Load({ Update-Layout; [LauncherNative]::AttachToTaskbar($bar.Handle); Start-IconPreload })

# ---- Suggestions menu (below or above the bar) ----
$pop = New-Object LauncherPopup
$pop.AutoScaleMode = 'None'
$pop.FormBorderStyle = 'None'
$pop.ShowInTaskbar = $false
$pop.StartPosition = 'Manual'
$pop.BackColor = $bgPop
$pop.Padding = New-Object Windows.Forms.Padding([int](6 * $scale))
$popW = [int](360 * $scale)

# The list's own scrollbar is pushed out of view by a clipping panel (always there, so rows keep the same width);
# a thin rounded thumb is drawn over the list instead.
$clip = New-Object Windows.Forms.Panel
$clip.Dock = 'Fill'
$list = New-Object Windows.Forms.ListBox
$list.ScrollAlwaysVisible = $true
$list.Font = New-Object Drawing.Font('Segoe UI', 11)
$list.BackColor = $bgPop
$list.ForeColor = [Drawing.Color]::Gainsboro
$list.BorderStyle = 'None'
$list.IntegralHeight = $false
$list.DrawMode = 'OwnerDrawFixed'
$list.ItemHeight = [int](34 * $scale)
$tagFont = New-Object Drawing.Font('Segoe UI', 8)
$clip.Controls.Add($list)
$pop.Controls.Add($clip)
$clip.Add_Resize({ $list.Bounds = New-Object Drawing.Rectangle(0, 0, ($clip.Width + [Windows.Forms.SystemInformation]::VerticalScrollBarWidth), $clip.Height); Update-Thumb })
# Normal searches show 10 results at most; game lists ("steam ", "gog ") keep up to 100 and scroll
$visibleRows = 10
$maxGames    = 100
$gamePrefix  = '^\s*(' + (($gameGroups.Values | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')\s'

$thumbCol  = [Drawing.Color]::FromArgb(95, 98, 108)
$thumbHot  = [Drawing.Color]::FromArgb(140, 144, 156)
$thumb = New-Object Windows.Forms.Panel
$thumb.Width = [int](4 * $scale)
$thumb.BackColor = $thumbCol
$thumb.Visible = $false
$clip.Controls.Add($thumb); $thumb.BringToFront()
function Update-Thumb {
    $n = $list.Items.Count; $vis = [Math]::Max(1, [int][Math]::Floor($list.ClientSize.Height / $list.ItemHeight))
    if ($n -le $vis) { if ($thumb.Visible) { $thumb.Visible = $false }; return }
    $trackH = $clip.Height - [int](4 * $scale)
    $h = [Math]::Max([int](24 * $scale), [int]($trackH * $vis / $n))
    $y = [int](2 * $scale) + [int](($trackH - $h) * [Math]::Min(1.0, $list.TopIndex / ($n - $vis)))
    $b = New-Object Drawing.Rectangle(($clip.Width - $thumb.Width - [int](2 * $scale)), $y, $thumb.Width, $h)
    if ($thumb.Bounds -ne $b) {
        $thumb.Bounds = $b
        $path = New-Object Drawing.Drawing2D.GraphicsPath   # rounded ends
        $d = $thumb.Width
        $path.AddArc(0, 0, $d, $d, 180, 180); $path.AddArc(0, $h - $d, $d, $d, 0, 180); $path.CloseFigure()
        $thumb.Region = New-Object Drawing.Region $path
    }
    if (-not $thumb.Visible) { $thumb.Visible = $true }
}
# Dragging the thumb scrolls the list
$thumb.Add_MouseEnter({ $thumb.BackColor = $thumbHot })
$thumb.Add_MouseLeave({ if (-not $script:thumbDrag) { $thumb.BackColor = $thumbCol } })
$thumb.Add_MouseDown({ $script:thumbDrag = @{ Y = [Windows.Forms.Control]::MousePosition.Y; Top = $list.TopIndex } })
$thumb.Add_MouseUp({ $script:thumbDrag = $null; if (-not $thumb.ClientRectangle.Contains($thumb.PointToClient([Windows.Forms.Control]::MousePosition))) { $thumb.BackColor = $thumbCol } })
$thumb.Add_MouseMove({
    if (-not $script:thumbDrag) { return }
    $n = $list.Items.Count; $vis = [int][Math]::Floor($list.ClientSize.Height / $list.ItemHeight)
    $span = $clip.Height - [int](4 * $scale) - $thumb.Height
    if ($span -le 0 -or $n -le $vis) { return }
    $dy = [Windows.Forms.Control]::MousePosition.Y - $script:thumbDrag.Y
    $list.TopIndex = [Math]::Max(0, [Math]::Min($n - $vis, $script:thumbDrag.Top + [int][Math]::Round($dy * ($n - $vis) / $span)))
    Update-Thumb
})
# The focus stays in the box: wheel over the box scrolls the suggestions too
$box.Add_MouseWheel({ if ($pop.Visible) { $list.TopIndex = [Math]::Max(0, $list.TopIndex - [Math]::Sign($_.Delta) * 3); Update-Thumb } })

# Draws one row: icon + name
$list.Add_DrawItem({
    param($s, $e)
    if ($e.Index -lt 0 -or $e.Index -ge $script:results.Count) { return }
    $gr = $e.Graphics
    $sel = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $gr.FillRectangle($(if ($sel) { $brSel } else { $brBg }), $e.Bounds)
    $isz = [int](24 * $scale); $pad = [int](8 * $scale)
    $ico = Get-AppIcon $script:results[$e.Index]
    if ($ico) {
        $gr.InterpolationMode = 'HighQualityBicubic'
        $gr.DrawImage($ico, $e.Bounds.X + $pad, $e.Bounds.Y + [int](($e.Bounds.Height - $isz) / 2), $isz, $isz)
    }
    $tx = $e.Bounds.X + $pad * 2 + $isz
    $right = $e.Bounds.Right - $pad
    # Kind tag on the right for anything that isn't a plain app ("Control Panel", "Settings", "Shortcut"...)
    $kind = $script:results[$e.Index].Kind
    if ($kind -and $kind -ne 'App') {
        $kw = [Windows.Forms.TextRenderer]::MeasureText($kind, $tagFont).Width
        $kr = New-Object Drawing.Rectangle(($right - $kw), $e.Bounds.Y, $kw, $e.Bounds.Height)
        $tagFlags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Right, SingleLine, NoPrefix'
        [Windows.Forms.TextRenderer]::DrawText($gr, $kind, $tagFont, $kr, $(if ($sel) { [Drawing.Color]::LightGray } else { [Drawing.Color]::Gray }), $tagFlags)
        $right -= $kw + $pad
    }
    $rect = New-Object Drawing.Rectangle($tx, $e.Bounds.Y, ($right - $tx), $e.Bounds.Height)
    $col = if ($sel) { [Drawing.Color]::White } else { [Drawing.Color]::Gainsboro }
    $flags = [Windows.Forms.TextFormatFlags]'VerticalCenter, Left, SingleLine, EndEllipsis, NoPrefix'
    [Windows.Forms.TextRenderer]::DrawText($gr, [string]$list.Items[$e.Index], $list.Font, $rect, $col, $flags)
    Update-Thumb   # rows get redrawn whenever the list scrolls (wheel, arrows)
})

$script:results = @()
$script:aliasMode = $null
$arrow = [string][char]0x2192

function Update-BarIcon {
    $i = $list.SelectedIndex
    $img = if ($box.Text -and $i -ge 0 -and $i -lt $script:results.Count) { Get-AppIcon $script:results[$i] } else { $null }
    $pic.Image = if ($img) { $img } else { $script:magnifier }
}
$list.Add_SelectedIndexChanged({ Update-BarIcon })

function Show-Results {
    # "ch=chrome": alias creation mode
    if ($box.Text -match '^\s*([^=]+?)\s*=\s*(.*)$') {
        $script:aliasMode = $Matches[1]
        $q = $Matches[2]
    } else {
        $script:aliasMode = $null
        $q = $box.Text
    }
    $script:results = @(Find-Apps $q $(if ($q -match $gamePrefix) { $maxGames } else { $visibleRows }))
    $list.BeginUpdate(); $list.Items.Clear()
    foreach ($a in $script:results) {
        if ($script:aliasMode) { [void]$list.Items.Add("Alias  $($script:aliasMode)  $arrow  $($a.Name)") }
        else { [void]$list.Items.Add((Get-AppLabel $a)) }
    }
    if ($list.Items.Count) { $list.SelectedIndex = 0 }
    $list.EndUpdate()
    Update-BarIcon
    if (-not $list.Items.Count) { $pop.Hide(); return }
    # At most $visibleRows rows; beyond that the list scrolls (wheel, Up/Down, scrollbar)
    $ph = [Math]::Min($list.Items.Count, $visibleRows) * $list.ItemHeight + [int](12 * $scale) + 4
    $px = [Math]::Min($script:barX, [Windows.Forms.Screen]::PrimaryScreen.Bounds.Right - $popW - 4)
    # Taskbar at the top: suggestions below; at the bottom: above
    $py = if ($script:tbAtTop) { $script:tbBottom + [int](6 * $scale) } else { $script:tbTop - $ph - [int](6 * $scale) }
    $pop.Bounds = New-Object Drawing.Rectangle($px, $py, $popW, $ph)
    $list.TopIndex = 0; Update-Thumb
    if (-not $pop.Visible) { $pop.Show() }
    [LauncherNative]::AttachToTaskbar($pop.Handle)
    [LauncherNative]::KeepOnTop($pop.Handle)
    if (-not $box.Focused) { $box.Focus() }
}

function Reset-Bar { $box.Text = ''; $pop.Hide(); $pic.Image = $script:magnifier }

# Short temporary message shown in the empty bar
$flashTimer = New-Object Windows.Forms.Timer
$flashTimer.Interval = 2500
$flashTimer.Add_Tick({ $flashTimer.Stop(); [LauncherNative]::Placeholder($box.Handle, '') })
function Show-Flash([string]$msg) {
    [LauncherNative]::Placeholder($box.Handle, $msg)
    $flashTimer.Stop(); $flashTimer.Start()
}

function Start-Choice {
    $app = if ($list.SelectedIndex -ge 0 -and $script:results.Count) { $script:results[$list.SelectedIndex] } else { $null }
    if ($box.Text.Trim() -eq ':alias') { Reset-Bar; Show-AliasManager; return }
    if ($script:aliasMode) {
        $alias = $script:aliasMode
        $target = if ($app) { $app.Name } else { ($box.Text -split '=', 2)[1] }
        if ($target.Trim()) {
            Add-Alias $alias $target
            Reset-Bar
            Show-Flash ([char]0x2713 + " $alias $arrow $target")
        }
        return
    }
    if (Invoke-Launch $app $box.Text) { Reset-Bar }
}

# Right-click on a suggestion: give it an alias
$itemMenu = New-Object Windows.Forms.ContextMenuStrip
[void]$itemMenu.Items.Add('Give this app an alias', $null, {
    $i = $list.SelectedIndex
    if ($i -ge 0 -and $i -lt $script:results.Count) {
        # Puts "=AppName" in the bar, cursor at the start: just type the alias and press Enter
        $name = $script:results[$i].Name
        $pop.Hide()
        [LauncherNative]::Front($bar.Handle)
        $box.Focus()
        $box.Text = "=$name"
        $box.SelectionStart = 0
        $box.SelectionLength = 0
    }
})
$list.ContextMenuStrip = $itemMenu
# Dark menus: shared renderer, roomier items
$darkMenu = New-Object DarkMenuRenderer
function Set-DarkMenu($m, [bool]$checks) {
    $m.Renderer = $darkMenu; $m.Font = New-Object Drawing.Font('Segoe UI', 10)
    $m.ShowImageMargin = $false; $m.ShowCheckMargin = $checks
    foreach ($i in $m.Items) { if ($i -is [Windows.Forms.ToolStripMenuItem]) { $i.Padding = New-Object Windows.Forms.Padding([int](6 * $scale), [int](4 * $scale), [int](12 * $scale), [int](4 * $scale)) } }
}
Set-DarkMenu $itemMenu $false
$list.Add_MouseDown({ if ($_.Button -eq 'Right') { $i = $list.IndexFromPoint($_.Location); if ($i -ge 0) { $list.SelectedIndex = $i } } })

$box.Add_GotFocus({ $n = $script:apps.Count; Update-AppsIfStale; if ($script:apps.Count -ne $n) { Start-IconPreload }; if ($box.Text) { Show-Results } })
$box.Add_TextChanged({ if ($box.Text) { Show-Results } else { $pop.Hide(); $pic.Image = $script:magnifier } })
$box.Add_KeyDown({
    param($s, $e)
    # Ctrl+Space: clear the whole field, keep the cursor in it (Esc does the same)
    if ($e.Control -and -not $e.Alt -and [int]$e.KeyCode -eq 32) { $e.SuppressKeyPress = $true; Reset-Bar; return }
    # Ctrl+Backspace: delete the previous word, like everywhere else
    # (by default a WinForms text box would insert a strange box character instead)
    if ($e.Control -and -not $e.Alt -and [int]$e.KeyCode -eq 8) {
        $e.SuppressKeyPress = $true
        $p = $box.SelectionStart
        if ($box.SelectionLength) { $box.SelectedText = ''; return }
        $before = $box.Text.Substring(0, $p) -replace '\S*\s*$', ''
        $box.Text = $before + $box.Text.Substring($p)
        $box.SelectionStart = $before.Length
        return
    }
    switch ([int]$e.KeyCode) {   # 40 Down, 38 Up, 13 Enter, 27 Esc
        40 { if (-not $pop.Visible) { Show-Results } elseif ($list.SelectedIndex -lt $list.Items.Count - 1) { $list.SelectedIndex++ }; $e.SuppressKeyPress = $true }
        38 { if ($list.SelectedIndex -gt 0) { $list.SelectedIndex-- }; $e.SuppressKeyPress = $true }
        13 { $e.SuppressKeyPress = $true; Start-Choice }
        27 {   # Esc: clear and leave the bar, back to the window used before
            $e.SuppressKeyPress = $true; Reset-Bar
            if ([LauncherNative]::Alive($script:prevWin)) { [LauncherNative]::Front($script:prevWin) }
        }
    }
})
# Launch on left button release over a suggestion (MouseUp: MouseClick isn't raised reliably on this no-activate popup)
$list.Add_MouseUp({ if ($_.Button -ne 'Left') { return }; $i = $list.IndexFromPoint($_.Location); if ($i -ge 0) { $list.SelectedIndex = $i; Start-Choice } })
$bar.Add_MouseDown({ [LauncherNative]::Front($bar.Handle); $box.Focus() })
$pic.Add_MouseDown({ [LauncherNative]::Front($bar.Handle); $box.Focus() })
$box.Add_MouseDown({ [LauncherNative]::Front($bar.Handle) })

# Clicking elsewhere clears the bar and hides the suggestions
# (but not a click on the suggestion list itself: that click must still reach the list and launch the app)
$bar.Add_Deactivate({
    if ($pop.Visible -and $pop.Bounds.Contains([Windows.Forms.Control]::MousePosition)) { return }
    Reset-Bar
})

# Stay above the taskbar, and in the right place
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 500
$script:hidden = $false
$script:prevWin = [IntPtr]::Zero
$timer.Add_Tick({
    $f = [LauncherNative]::OtherForeground(); if ($f -ne [IntPtr]::Zero) { $script:prevWin = $f }
    # Full screen (movie, game...): the taskbar goes away, so does the search bar
    if ([LauncherNative]::FullscreenApp()) {
        if (-not $script:hidden) { $pop.Hide(); [LauncherNative]::Hide($bar.Handle); $script:hidden = $true }
        return
    }
    if ($script:hidden) { [LauncherNative]::ShowNoActivate($bar.Handle); $script:hidden = $false }
    Update-Layout
    [LauncherNative]::AttachToTaskbar($bar.Handle)   # redone if Explorer restarted
    [LauncherNative]::KeepOnTop($bar.Handle)
    Update-StartButton   # redone if Explorer brought the button back or re-laid out the taskbar
})
$timer.Start()

# Refresh the app list every 30 min, only when not typing
$refresh = New-Object Windows.Forms.Timer
$refresh.Interval = 30 * 60 * 1000
$refresh.Add_Tick({ if (-not $box.Focused) { Import-Apps; Start-IconPreload } })   # icon cache kept: only new apps get loaded
$refresh.Start()

# Installed or uninstalled a program: Windows tells us (Start menu folders changed), the list reloads
# a few seconds later (an installer writes several files), never while typing. Store apps: the 30 min refresh.
$reload = New-Object Windows.Forms.Timer
$reload.Interval = 3000
$reload.Add_Tick({ if (-not $box.Focused -or -not $box.Text) { $reload.Stop(); Write-Log 'Start menu changed: reloading apps'; Import-Apps; Start-IconPreload } })
$script:watchers = foreach ($d in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('CommonPrograms'))) {
    if (-not (Test-Path -LiteralPath $d)) { continue }
    $w = New-Object IO.FileSystemWatcher $d
    $w.IncludeSubdirectories = $true
    $w.NotifyFilter = [IO.NotifyFilters]'FileName, DirectoryName'
    $w.SynchronizingObject = $bar   # events arrive on the UI thread
    $onChange = { $reload.Stop(); $reload.Start() }
    $w.Add_Created($onChange); $w.Add_Deleted($onChange); $w.Add_Renamed($onChange)
    $w.EnableRaisingEvents = $true
    $w
}

# Windows key alone opens the bar (Ctrl+Esc still opens the Start menu)
$hk = New-Object LauncherNative
if ($WindowsKey) { $hk.StartWinKey() }
$hk.add_HotKey({ $f = [LauncherNative]::OtherForeground(); if ($f -ne [IntPtr]::Zero) { $script:prevWin = $f }; if ($script:hidden) { [LauncherNative]::ShowNoActivate($bar.Handle); $script:hidden = $false }; [LauncherNative]::Front($bar.Handle); $bar.Activate(); $box.Focus(); $box.SelectAll() })

# Right-click menu: aliases, shortcuts folder, move to the other side, quit
$menu = New-Object Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add('Aliases', $null, { Reset-Bar; Show-AliasManager })
[void]$menu.Items.Add('Shortcuts', $null, { Reset-Bar; Start-Process explorer.exe "`"$shortcutDir`"" })   # new files show up in the search by themselves
# One item that names the other side (top / bottom follows the taskbar)
$miMove = $menu.Items.Add('Move to left', $null, { Set-Side $(if ($script:side -eq 'Left') { 'Right' } else { 'Left' }) })
$menu.Add_Opening({ $miMove.Text = if ($script:side -eq 'Left') { 'Move to right' } else { 'Move to left' } })
[void]$menu.Items.Add('-')
[void]$menu.Items.Add('Quit', $null, { Write-Log 'Quit (menu)'; Set-Content $stopFlag '' -ErrorAction SilentlyContinue; $bar.Close() })
Set-DarkMenu $menu $false
$bar.ContextMenuStrip = $menu
$box.ContextMenuStrip = $menu
$pic.ContextMenuStrip = $menu

try { [Windows.Forms.Application]::Run($bar) }
catch { Write-Log "Stopped on error: $($_.Exception.Message)" }
if ($script:startHidden) { [LauncherNative]::StartButton($true, 0) }   # give the Start button back when the bar closes
Write-Log 'Stop'
$mutex.ReleaseMutex()
