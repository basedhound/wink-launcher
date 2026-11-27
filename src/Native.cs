// Windows plumbing for the bar: the suggestion window, dark menus, the taskbar, the Windows key, icons.
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

// Owner for the alias window: the desktop, not the bar (a window owned by an always-on-top window
// is always on top too, and other windows couldn't go over it)
public class DesktopOwner : IWin32Window {
    [DllImport("user32.dll")] static extern IntPtr GetDesktopWindow();
    public IntPtr Handle { get { return GetDesktopWindow(); } }
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
    static readonly Color Text = Color.FromArgb(235, 235, 235), Line = Color.FromArgb(70, 70, 70), Hover = Color.FromArgb(62, 62, 62);
    public DarkMenuRenderer() : base(new DarkMenuColors()) { RoundedEdges = false; }
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
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool EnableWindow(IntPtr h, bool on);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessage(IntPtr h, int msg, IntPtr w, string l);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindow(string c, string t);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr FindWindowEx(IntPtr p, IntPtr after, string c, string t);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, System.Text.StringBuilder s, int n);

    // ---- Windows key alone: opens the bar instead of the Start menu ----
    // Low-level keyboard hook on its own thread (typing never lags, even when the bar is busy).
    // Win+E, Win+D... keep working: we only react when the Windows key is released with no other key in between.
    public event EventHandler HotKey;
    public LauncherNative() { CreateHandle(new CreateParams()); }
    protected override void WndProc(ref Message m) {
        if (m.Msg == 0x8001 && HotKey != null) HotKey(this, EventArgs.Empty);   // Windows key tapped (WM_APP+1, posted by the hook)
        base.WndProc(ref m);
    }
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

    // ---- Windows and focus ----
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
    public static IntPtr OtherForeground() {
        IntPtr f = GetForegroundWindow(); uint pid; GetWindowThreadProcessId(f, out pid);
        return (f == IntPtr.Zero || pid == (uint)System.Diagnostics.Process.GetCurrentProcess().Id) ? IntPtr.Zero : f;
    }
    public static bool Alive(IntPtr h) { return h != IntPtr.Zero && IsWindow(h); }
    public static void Hide(IntPtr h) { ShowWindow(h, 0); }
    public static void ShowNoActivate(IntPtr h) { ShowWindow(h, 4); }
    public static void Enable(IntPtr h) { EnableWindow(h, true); }
    public static void Placeholder(IntPtr box, string text) { SendMessage(box, 0x1501, new IntPtr(1), text); }   // EM_SETCUEBANNER
    // Dark title bar (Windows 10 20H1+ / 11; attribute 19 on older 10 builds) and dark scrollbars
    [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int attr, ref int v, int size);
    [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] static extern int SetWindowTheme(IntPtr h, string app, string id);
    public static void DarkTitle(IntPtr h) { int on = 1; if (DwmSetWindowAttribute(h, 20, ref on, 4) != 0) DwmSetWindowAttribute(h, 19, ref on, 4); }
    public static void DarkScroll(IntPtr h) { SetWindowTheme(h, "DarkMode_Explorer", null); }

    // Is a window (movie, game, slideshow...) full screen on the primary display?
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
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

    // ---- The taskbar ----
    // Taskbar rectangle (empty if not found)
    public static Rectangle Taskbar() {
        IntPtr t = FindWindow("Shell_TrayWnd", null); RECT r;
        if (t == IntPtr.Zero || !GetWindowRect(t, out r)) return Rectangle.Empty;
        return Rectangle.FromLTRB(r.L, r.T, r.R, r.B);
    }
    // Left edge of the clock / system icons area (0 if not found)
    public static int TrayLeft() {
        IntPtr t = FindWindow("Shell_TrayWnd", null); if (t == IntPtr.Zero) return 0;
        IntPtr n = FindWindowEx(t, IntPtr.Zero, "TrayNotifyWnd", null); RECT r;
        if (n == IntPtr.Zero || !GetWindowRect(n, out r)) return 0;
        return r.L;
    }
    // Ties the window to the taskbar: an "owned" window always stays above its owner,
    // even when the Start menu brings the taskbar back to the front.
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")] static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    public static void AttachToTaskbar(IntPtr h) {
        IntPtr t = FindWindow("Shell_TrayWnd", null);
        if (t != IntPtr.Zero && GetWindowLongPtr(h, -8) != t) SetWindowLongPtr(h, -8, t);   // GWLP_HWNDPARENT
    }

    // Shows / hides the taskbar's Start button (the Start menu itself still opens with Ctrl+Esc).
    // Explorer may show it again (taskbar rebuilt, Explorer restarted), so this is called from the bar's timer.
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
    // An icon stored in a file at an index ("shell32.dll,27"), with transparency
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHDefExtractIcon(string path, int index, uint flags, out IntPtr large, out IntPtr small, uint size);
    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);
    public static Bitmap FromResource(string path, int index, int size) {
        IntPtr large, small;
        if (SHDefExtractIcon(path, index, 0, out large, out small, (uint)size) != 0 || large == IntPtr.Zero) return null;
        try { using (var ico = Icon.FromHandle(large)) return ico.ToBitmap(); }
        finally { DestroyIcon(large); }
    }
    // A picture used as an icon (Steam games keep theirs as small jpgs): the shell would only give
    // the generic picture-file icon, so the picture itself is scaled down
    public static Bitmap FromPicture(string path, int size) {
        try {
            using (var src = new Bitmap(new System.IO.MemoryStream(System.IO.File.ReadAllBytes(path)))) {
                var img = new Bitmap(size, size);
                using (var g = Graphics.FromImage(img)) {
                    g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                    g.DrawImage(src, 0, 0, size, size);
                }
                return img;
            }
        } catch { return null; }
    }
}
