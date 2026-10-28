param(
    # The launcher window - what forms.newform() returned in launcher.lua.
    # BizHawk's main window is found from it (it's the launcher's owner).
    [Parameter(Mandatory = $true)][long]$Hwnd,

    # Shape of the game picture BizHawk is sized around: the Game Boy's
    # 160x144. BizHawk keeps the picture's aspect ratio and fills the rest
    # with black, so matching it exactly means no black bars.
    [double]$GameAspect = 160 / 144,

    # Space between the two windows' visible edges.
    [int]$Gap = 0,

    # Only line the windows up (at start and after a ROM opens), without
    # keeping them stuck together in between.
    [switch]$NoDock
)

# ===================================================================
#  Puts BizHawk's main window and the launcher side by side - BizHawk on
#  the left, the launcher right next to it, top edges lined up - with
#  BizHawk sized to the launcher's height (and to whatever width fits the
#  game picture at that height), then keeps the two docked as one unit:
#    * drag either window and the other one comes along;
#    * resize BizHawk and the launcher follows its height (never getting
#      shorter than its own content). When you let go, BizHawk's other
#      side snaps to fit the game picture - no black bars - and it's kept
#      at least as tall as the launcher;
#    * open a ROM (BizHawk then resizes itself to its zoom setting) and
#      both go back to the matched sizes from the start.
#  BizHawk maximized or minimized is left alone. BizHawk's Lua API can read
#  the main window's position but not move it, hence this helper.
#
#  Driven by Windows' own "window moved/resized" events for BizHawk's
#  process (SetWinEventHook) rather than polling, so the other window keeps
#  up while you drag and nothing runs while nothing moves. Exits when
#  either window closes.
#
#  Works on the windows' VISIBLE edges (DWM's extended frame bounds), not
#  their raw rectangles - Windows 10 gives windows invisible resize borders
#  several pixels wide, which would otherwise leave a gap between them.
# ===================================================================

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;

public static class AutocrystalDock {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX, ptY; }
    public delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    public delegate bool EnumChildProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr hWnd, UIntPtr id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] static extern bool KillTimer(IntPtr hWnd, UIntPtr id);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr hWnd);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr hWnd, uint cmd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumChildProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int max);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT rect, int size);

    const uint GW_OWNER = 4;
    const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A, EVENT_SYSTEM_MOVESIZEEND = 0x000B;
    const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B, EVENT_OBJECT_NAMECHANGE = 0x800C;
    const uint WINEVENT_OUTOFCONTEXT = 0;
    const uint WM_TIMER = 0x0113;
    // No z-order change, never activate (never steals focus), and don't
    // wait on BizHawk's UI thread, which may be busy running the bot.
    const uint SWP_NOSIZE = 0x1, SWP_NOZORDER = 0x4, SWP_NOACTIVATE = 0x10, SWP_ASYNCWINDOWPOS = 0x4000;
    const uint MOVE_FLAGS = SWP_NOZORDER | SWP_NOACTIVATE | SWP_ASYNCWINDOWPOS;

    // A window's visible rectangle, plus how far that sits inside its raw
    // rectangle on each side (the invisible resize borders).
    struct Frame {
        public RECT Vis; public int L, T, R, B;
        public int W { get { return Vis.Right - Vis.Left; } }
        public int H { get { return Vis.Bottom - Vis.Top; } }
    }
    class Placement { public IntPtr Hwnd; public RECT Vis; public DateTime At; }

    static IntPtr biz, launcher;
    static double aspect;
    static int gap, naturalHeight;
    static bool dock;
    static string lastTitle;
    static DateTime titleChangedAt = DateTime.MinValue, selfResizedAt = DateTime.MinValue;
    static int knownW, knownH;
    static bool userSizing;
    static int sizingStartW, sizingStartH;
    static UIntPtr arrangeTimer;
    static readonly List<Placement> placements = new List<Placement>();
    static WinEventProc eventProc; // kept in a field so it's never garbage-collected

    static RECT Rect(int x, int y, int w, int h) {
        RECT r; r.Left = x; r.Top = y; r.Right = x + w; r.Bottom = y + h;
        return r;
    }
    static bool Near(RECT a, RECT b) {
        return Math.Abs(a.Left - b.Left) <= 1 && Math.Abs(a.Top - b.Top) <= 1
            && Math.Abs(a.Right - b.Right) <= 1 && Math.Abs(a.Bottom - b.Bottom) <= 1;
    }

    static Frame GetFrame(IntPtr h) {
        RECT raw, vis;
        GetWindowRect(h, out raw);
        if (DwmGetWindowAttribute(h, 9 /* DWMWA_EXTENDED_FRAME_BOUNDS */, out vis, 16) != 0) vis = raw;
        Frame f = new Frame();
        f.Vis = vis;
        f.L = vis.Left - raw.Left; f.T = vis.Top - raw.Top; f.R = raw.Right - vis.Right; f.B = raw.Bottom - vis.Bottom;
        return f;
    }

    static string Title(IntPtr h) {
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    // The biggest visible child window - BizHawk's game picture panel (the
    // menu bar is the only other sizable child).
    static RECT LargestChild(IntPtr parent) {
        RECT best = new RECT(); long bestArea = 0;
        EnumChildWindows(parent, delegate(IntPtr h, IntPtr l) {
            RECT r;
            if (IsWindowVisible(h) && GetWindowRect(h, out r)) {
                long area = (long)(r.Right - r.Left) * (r.Bottom - r.Top);
                if (area > bestArea) { bestArea = area; best = r; }
            }
            return true;
        }, IntPtr.Zero);
        return best;
    }

    // Size of everything around BizHawk's game picture - title bar, menu,
    // borders. That part stays the same however big the window gets.
    static bool Chrome(Frame b, out int chromeW, out int chromeH) {
        RECT pic = LargestChild(biz);
        chromeW = b.W - (pic.Right - pic.Left);
        chromeH = b.H - (pic.Bottom - pic.Top);
        return pic.Right > pic.Left && pic.Bottom > pic.Top && chromeW >= 0 && chromeH >= 0;
    }
    static int WidthFor(int height, int chromeW, int chromeH) {
        return (int)Math.Round((height - chromeH) * aspect) + chromeW;
    }

    // The launcher's own height (all of its content), or the screen's if
    // that's smaller.
    static int FullHeight() {
        return Math.Min(naturalHeight, Screen.FromHandle(biz).WorkingArea.Height);
    }

    // Every position this helper gives a window is remembered for a
    // moment, so the move Windows then reports back for it is recognised
    // as an echo rather than taken for the user moving that window -
    // otherwise the two windows would end up chasing each other.
    static bool IsEcho(IntPtr h, RECT vis) {
        DateTime now = DateTime.Now;
        placements.RemoveAll(p => (now - p.At).TotalMilliseconds > 1000);
        int i = placements.FindIndex(p => p.Hwnd == h && Near(p.Vis, vis));
        if (i < 0) return false;
        for (int j = i; j >= 0; j--) if (placements[j].Hwnd == h) placements.RemoveAt(j);
        return true;
    }

    static void Place(IntPtr h, Frame f, RECT to, bool resize) {
        if (!resize) to = Rect(to.Left, to.Top, f.W, f.H);
        if (Near(f.Vis, to)) return;
        Placement p = new Placement(); p.Hwnd = h; p.Vis = to; p.At = DateTime.Now;
        placements.Add(p);
        SetWindowPos(h, IntPtr.Zero, to.Left - f.L, to.Top - f.T,
            (to.Right - to.Left) + f.L + f.R, (to.Bottom - to.Top) + f.T + f.B,
            resize ? MOVE_FLAGS : MOVE_FLAGS | SWP_NOSIZE);
    }

    // The launcher goes right next to BizHawk, top edges lined up, as tall
    // as BizHawk but never shorter than its own content.
    static void Beside(RECT bv) {
        if (IsIconic(launcher)) return;
        Frame l = GetFrame(launcher);
        Place(launcher, l, Rect(bv.Right + gap, bv.Top, l.W, Math.Max(bv.Bottom - bv.Top, FullHeight())), true);
    }

    // The launcher was dragged: BizHawk goes back to its left (same size).
    static void FollowLauncher(Frame l) {
        Frame b = GetFrame(biz);
        Place(biz, b, Rect(l.Vis.Left - gap - b.W, l.Vis.Top, b.W, b.H), false);
    }

    // The matched layout: BizHawk sized around the game picture at the
    // launcher's own height, launcher right next to it. BizHawk stays where
    // it is, unless that would push the pair past its monitor's edge.
    static void Arrange() {
        if (IsIconic(biz) || IsZoomed(biz)) return;
        Frame b = GetFrame(biz), l = GetFrame(launcher);
        int chromeW, chromeH, height = FullHeight();
        if (!Chrome(b, out chromeW, out chromeH) || chromeH >= height) return;
        int width = WidthFor(height, chromeW, chromeH);

        System.Drawing.Rectangle area = Screen.FromHandle(biz).WorkingArea;
        int x = b.Vis.Left, y = b.Vis.Top, total = width + gap + l.W;
        if (x + total > area.Right) x = Math.Max(area.Left, area.Right - total);
        if (y + height > area.Bottom) y = Math.Max(area.Top, area.Bottom - height);
        RECT to = Rect(x, y, width, height);
        Place(biz, b, to, true);
        Beside(to);
    }

    // The user let go of BizHawk's border: fit the other side to the game
    // picture (keeping the side they dragged), at least as tall as the
    // launcher's content.
    static void FitAfterResize() {
        if (IsIconic(biz) || IsZoomed(biz)) return;
        Frame b = GetFrame(biz);
        int dW = b.W - sizingStartW, dH = b.H - sizingStartH;
        int chromeW, chromeH;
        if ((dW == 0 && dH == 0) || !Chrome(b, out chromeW, out chromeH)) return;
        System.Drawing.Rectangle area = Screen.FromHandle(biz).WorkingArea;
        int height = b.H;
        if (Math.Abs(dW) > Math.Abs(dH) * aspect) // mostly a sideways drag
            height = (int)Math.Round((b.W - chromeW) / aspect) + chromeH;
        height = Math.Min(Math.Max(height, FullHeight()), area.Height);
        int y = Math.Max(area.Top, Math.Min(b.Vis.Top, area.Bottom - height));
        RECT to = Rect(b.Vis.Left, y, WidthFor(height, chromeW, chromeH), height);
        Place(biz, b, to, true);
        Beside(to);
    }

    static void ScheduleArrange(uint ms) {
        if (arrangeTimer != UIntPtr.Zero) KillTimer(IntPtr.Zero, arrangeTimer);
        arrangeTimer = SetTimer(IntPtr.Zero, UIntPtr.Zero, ms, IntPtr.Zero);
    }

    static void OnEvent(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
        // Only the two windows themselves, not their controls.
        if (idObject != 0 || idChild != 0 || (hwnd != biz && hwnd != launcher)) return;

        if (hwnd == launcher) {
            if (evt != EVENT_OBJECT_LOCATIONCHANGE || !dock || IsIconic(launcher) || IsIconic(biz) || IsZoomed(biz)) return;
            Frame l = GetFrame(launcher);
            if (!IsEcho(launcher, l.Vis)) FollowLauncher(l);
            return;
        }

        // A ROM opening or closing shows up as a title change plus BizHawk
        // resizing itself to its zoom setting (not the user dragging it),
        // within a moment of each other. Then the matched sizes come back -
        // once the resizing has settled, as it can take a few steps.
        if (evt == EVENT_OBJECT_NAMECHANGE) {
            string title = Title(biz);
            if (title == lastTitle) return;
            lastTitle = title;
            titleChangedAt = DateTime.Now;
            if ((titleChangedAt - selfResizedAt).TotalMilliseconds < 3000) ScheduleArrange(300);
        } else if (evt == EVENT_SYSTEM_MOVESIZESTART) {
            Frame s = GetFrame(biz);
            userSizing = true; sizingStartW = s.W; sizingStartH = s.H;
        } else if (evt == EVENT_SYSTEM_MOVESIZEEND) {
            userSizing = false;
            if (dock) FitAfterResize();
        } else if (evt == EVENT_OBJECT_LOCATIONCHANGE && !IsIconic(biz) && !IsZoomed(biz)) {
            Frame b = GetFrame(biz);
            bool resized = b.W != knownW || b.H != knownH;
            knownW = b.W; knownH = b.H;
            if (IsEcho(biz, b.Vis)) return;
            if (dock) Beside(b.Vis);
            if (resized && !userSizing) {
                selfResizedAt = DateTime.Now;
                if ((selfResizedAt - titleChangedAt).TotalMilliseconds < 3000) ScheduleArrange(300);
            }
        }
    }

    public static void Run(IntPtr launcherHwnd, double gameAspect, int gapPx, bool keepDocked) {
        SetProcessDPIAware();
        launcher = launcherHwnd; aspect = gameAspect; gap = gapPx; dock = keepDocked;
        biz = GetWindow(launcher, GW_OWNER);
        if (biz == IntPtr.Zero) return;

        // The launcher sizes itself right as it starts - wait until its
        // height has held steady for a moment before measuring it.
        int last = -1;
        for (int i = 0; i < 20; i++) {
            int h = GetFrame(launcher).H;
            if (h == last) break;
            last = h;
            Thread.Sleep(300);
        }
        naturalHeight = last;
        lastTitle = Title(biz);
        Arrange();
        knownW = GetFrame(biz).W; knownH = GetFrame(biz).H;

        uint pid;
        GetWindowThreadProcessId(biz, out pid);
        eventProc = OnEvent;
        IntPtr sizeHook = SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        IntPtr moveHook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        // Once a second: are both windows still open?
        SetTimer(IntPtr.Zero, UIntPtr.Zero, 1000, IntPtr.Zero);

        // The events arrive through this thread's message queue.
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            if (msg.message == WM_TIMER) {
                if (!IsWindow(biz) || !IsWindow(launcher)) break;
                if (arrangeTimer != UIntPtr.Zero && (ulong)msg.wParam.ToInt64() == arrangeTimer.ToUInt64()) {
                    KillTimer(IntPtr.Zero, arrangeTimer);
                    arrangeTimer = UIntPtr.Zero;
                    Arrange();
                }
                continue;
            }
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
        UnhookWinEvent(sizeHook);
        UnhookWinEvent(moveHook);
    }
}
"@

[AutocrystalDock]::Run([IntPtr]$Hwnd, $GameAspect, $Gap, -not $NoDock)
