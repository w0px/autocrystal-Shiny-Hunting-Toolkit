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
#  Two of the bot's other windows dock too, while they're open: Game Assistant
#  against BizHawk's left side, Encounter Stats against the launcher's
#  right side, tops lined up, as tall as the launcher. The launcher sizes
#  itself to its open panels (folding one changes its height) and BizHawk
#  takes its height; the Game Assistant scrolls by mouse wheel instead,
#  its scroll bars kept hidden (HideScrollBars). They come along whenever
#  the pair moves, and dragging one moves the whole group. Each is found by
#  its exact title - its "Detach" button adds " (detached)" to the title,
#  so it's let go of (and "Attach" or reopening it docks it again). A
#  docked window never leaves its monitor: when the screen runs out it
#  slides over its neighbour, and when one docks the group shifts to make
#  room if it can.
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
    [DllImport("user32.dll")] static extern bool ShowScrollBar(IntPtr hWnd, int bar, bool show);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hWnd, int index);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumChildProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hWnd, int attribute, out RECT rect, int size);

    const uint GW_OWNER = 4;
    const uint EVENT_SYSTEM_MOVESIZESTART = 0x000A, EVENT_SYSTEM_MOVESIZEEND = 0x000B;
    const uint EVENT_OBJECT_LOCATIONCHANGE = 0x800B, EVENT_OBJECT_NAMECHANGE = 0x800C;
    const uint EVENT_OBJECT_DESTROY = 0x8001, EVENT_OBJECT_SHOW = 0x8002, EVENT_OBJECT_HIDE = 0x8003;
    const uint EVENT_OBJECT_VALUECHANGE = 0x800E;
    const int OBJID_VSCROLL = -5, OBJID_HSCROLL = -6, SB_BOTH = 3, GWL_STYLE = -16, WS_VSCROLL = 0x00200000, WS_HSCROLL = 0x00100000;
    const uint GA_ROOT = 2;
    const string LIVE_VIEW_TITLE = "Game Assistant", STATS_TITLE = "Encounter Stats";
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
    static IntPtr liveView = IntPtr.Zero, stats = IntPtr.Zero; // docked while open (see the top)
    static DateTime dockedAt = DateTime.MinValue; // when one last docked
    static int fittedH;      // the height Arrange() last gave BizHawk
    static bool launcherSizing;
    static uint bizPid;
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

    // The Game Assistant scrolls by mouse wheel with its scroll bars hidden:
    // WinForms shows them again whenever its content or size changes or it
    // scrolls, and Windows reports each time (EVENT_OBJECT_VALUECHANGE on the
    // bar) - hidden again right then. Docked or detached alike.
    static bool IsGameAssistant(IntPtr h) {
        string t = Title(h);
        return t != null && t.StartsWith(LIVE_VIEW_TITLE);
    }
    static void HideScrollBars(IntPtr h) {
        if (h == IntPtr.Zero || !IsWindow(h)) return;
        if ((GetWindowLong(h, GWL_STYLE) & (WS_VSCROLL | WS_HSCROLL)) != 0) ShowScrollBar(h, SB_BOTH, false);
    }

    // The launcher's height changed - it sizes itself to its open panels,
    // with no scroll bar. BizHawk (and so the rest) takes its height,
    // growing or shrinking with it; a size you gave BizHawk yourself stays,
    // unless it's too short.
    static void FitContent() {
        if (!dock || IsIconic(biz) || IsZoomed(biz)) return;
        Frame b = GetFrame(biz);
        if (b.H < FullHeight() || Math.Abs(b.H - fittedH) <= 1) Arrange();
        else Beside(b.Vis);
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
        // Kept (until it's a second old): Windows can report the same
        // placement twice, and the repeat is an echo too - otherwise a
        // stretched launcher reads as its panels being opened.
        for (int j = i - 1; j >= 0; j--) if (placements[j].Hwnd == h) placements.RemoveAt(j);
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

    // ===== The docked windows (Game Assistant, Encounter Stats) =====

    static bool Usable(IntPtr h) { return h != IntPtr.Zero && IsWindow(h) && !IsIconic(h); }

    // The visible top-level window of BizHawk's process with exactly this
    // title (GetWindowText reads another process's caption without asking
    // it, so a busy BizHawk can't hold this up).
    static IntPtr FindTitled(string title) {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr l) {
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            if (pid == bizPid && IsWindowVisible(h) && Title(h) == title) { found = h; return false; }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // How much room a docked window takes beside the pair (gap included).
    static int DockedWidth(IntPtr h) { return Usable(h) ? GetFrame(h).W + gap : 0; }

    // Game Assistant against BizHawk's left side, Encounter Stats against the
    // launcher's right side, tops lined up, as tall as the launcher (both
    // scroll when their content is taller) - each kept
    // inside its monitor, sliding over its neighbour if the screen runs out.
    static void PlaceDocked(RECT bv, RECT lv) {
        if (!dock) return;
        int height = lv.Bottom - lv.Top;
        if (Usable(liveView)) {
            Frame f = GetFrame(liveView);
            System.Drawing.Rectangle area = Screen.FromHandle(biz).WorkingArea;
            Place(liveView, f, Rect(Math.Max(area.Left, bv.Left - gap - f.W), bv.Top, f.W, height), true);
        }
        if (Usable(stats)) {
            Frame f = GetFrame(stats);
            System.Drawing.Rectangle area = Screen.FromHandle(launcher).WorkingArea;
            Place(stats, f, Rect(Math.Min(lv.Right + gap, area.Right - f.W), lv.Top, f.W, height), true);
        }
    }

    // The launcher goes right next to BizHawk, top edges lined up, as tall
    // as BizHawk but never shorter than its own content - and the docked
    // windows come along.
    static void Beside(RECT bv) {
        if (IsIconic(launcher)) return;
        Frame l = GetFrame(launcher);
        RECT to = Rect(bv.Right + gap, bv.Top, l.W, Math.Max(bv.Bottom - bv.Top, FullHeight()));
        Place(launcher, l, to, true);
        PlaceDocked(bv, to);
    }

    // The launcher was dragged: BizHawk goes back to its left (same size).
    static void FollowLauncher(Frame l) {
        Frame b = GetFrame(biz);
        RECT to = Rect(l.Vis.Left - gap - b.W, l.Vis.Top, b.W, b.H);
        Place(biz, b, to, false);
        PlaceDocked(to, l.Vis);
    }

    // Whether the Game Assistant still sits where docking put it (left of
    // BizHawk, or against the screen edge when there's no room).
    static bool SameLeft(IntPtr h, Frame f) {
        Frame b = GetFrame(biz);
        System.Drawing.Rectangle area = Screen.FromHandle(biz).WorkingArea;
        int expected = Math.Max(area.Left, b.Vis.Left - gap - f.W);
        return Math.Abs(f.Vis.Left - expected) <= 1;
    }

    // A docked window was dragged: the group follows it.
    static void FollowDocked(IntPtr h) {
        Frame f = GetFrame(h), b = GetFrame(biz), l = GetFrame(launcher);
        if (h == liveView) {
            RECT nb = Rect(f.Vis.Right + gap, f.Vis.Top, b.W, b.H);
            Place(biz, b, nb, false);
            RECT nl = Rect(nb.Right + gap, nb.Top, l.W, l.H);
            Place(launcher, l, nl, false);
            if (Usable(stats)) { Frame s = GetFrame(stats); Place(stats, s, Rect(nl.Right + gap, nl.Top, s.W, s.H), false); }
        } else {
            RECT nl = Rect(f.Vis.Left - gap - l.W, f.Vis.Top, l.W, l.H);
            Place(launcher, l, nl, false);
            RECT nb = Rect(nl.Left - gap - b.W, nl.Top, b.W, b.H);
            Place(biz, b, nb, false);
            if (Usable(liveView)) { Frame v = GetFrame(liveView); Place(liveView, v, Rect(nb.Left - gap - v.W, nb.Top, v.W, v.H), false); }
        }
    }

    // Shifts the whole group sideways so everything fits on BizHawk's
    // monitor - the left end first if it can't all fit.
    static void FitGroup() {
        if (IsIconic(biz) || IsZoomed(biz)) return;
        Frame b = GetFrame(biz), l = GetFrame(launcher);
        System.Drawing.Rectangle area = Screen.FromHandle(biz).WorkingArea;
        int left = b.Vis.Left - DockedWidth(liveView);
        int right = b.Vis.Right + gap + l.W + DockedWidth(stats);
        int shift = 0;
        if (right > area.Right) shift = -(right - area.Right);
        if (left + shift < area.Left) shift = area.Left - left;
        RECT to = Rect(b.Vis.Left + shift, b.Vis.Top, b.W, b.H);
        Place(biz, b, to, false);
        Beside(to);
    }

    // Looks the docked windows up again (one opened, closed, was detached
    // or attached); one that's newly there goes into place.
    static void RefreshDocked() {
        IntPtr v = FindTitled(LIVE_VIEW_TITLE), s = FindTitled(STATS_TITLE);
        bool fresh = (v != IntPtr.Zero && v != liveView) || (s != IntPtr.Zero && s != stats);
        liveView = v; stats = s;
        if (fresh && dock) {
            dockedAt = DateTime.Now;
            FitGroup();
        }
        HideScrollBars(v);
        HideScrollBars(FindTitled(LIVE_VIEW_TITLE + " (detached)"));
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
        int leftExtra = dock ? DockedWidth(liveView) : 0, rightExtra = dock ? DockedWidth(stats) : 0;
        int x = b.Vis.Left, y = b.Vis.Top, total = width + gap + l.W + rightExtra;
        if (x + total > area.Right) x = area.Right - total;
        if (x - leftExtra < area.Left) x = area.Left + leftExtra;
        if (y + height > area.Bottom) y = Math.Max(area.Top, area.Bottom - height);
        RECT to = Rect(x, y, width, height);
        fittedH = height;
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
        if ((idObject == OBJID_VSCROLL || idObject == OBJID_HSCROLL) && IsGameAssistant(hwnd)) {
            HideScrollBars(hwnd);
            return;
        }
        // Only windows themselves, not their controls.
        if (idObject != 0 || idChild != 0) return;

        // A window opened, closed or was renamed (Detach / Attach): look the
        // docked windows up again. BizHawk's own title change is a ROM, below.
        if (evt == EVENT_OBJECT_SHOW || evt == EVENT_OBJECT_HIDE || evt == EVENT_OBJECT_DESTROY
                || (evt == EVENT_OBJECT_NAMECHANGE && hwnd != biz)) {
            if (hwnd == liveView || hwnd == stats || GetAncestor(hwnd, GA_ROOT) == hwnd) RefreshDocked();
            return;
        }

        // A docked window dragged: the group follows. Except right after it
        // docked - Windows can report where it first opened only after this
        // has placed it, which isn't the user moving it: back into place.
        if ((hwnd == liveView || hwnd == stats) && evt == EVENT_OBJECT_LOCATIONCHANGE) {
            if (!dock || !Usable(hwnd) || IsIconic(biz) || IsZoomed(biz) || IsIconic(launcher)) return;
            if (IsEcho(hwnd, GetFrame(hwnd).Vis)) return;
            Frame f = GetFrame(hwnd);
            if (hwnd == liveView && Math.Abs(f.Vis.Top - GetFrame(biz).Vis.Top) <= 1 && SameLeft(hwnd, f)) {
                // Not moved, just another height: back to the launcher's - it
                // scrolls instead.
                PlaceDocked(GetFrame(biz).Vis, GetFrame(launcher).Vis);
            }
            else if ((DateTime.Now - dockedAt).TotalMilliseconds < 1000) PlaceDocked(GetFrame(biz).Vis, GetFrame(launcher).Vis);
            else FollowDocked(hwnd);
            return;
        }

        if (hwnd != biz && hwnd != launcher) return;

        if (hwnd == launcher) {
            if (evt == EVENT_SYSTEM_MOVESIZESTART) { launcherSizing = true; return; }
            if (evt == EVENT_SYSTEM_MOVESIZEEND) { launcherSizing = false; return; }
            if (evt != EVENT_OBJECT_LOCATIONCHANGE || !dock || IsIconic(launcher) || IsIconic(biz) || IsZoomed(biz)) return;
            Frame l = GetFrame(launcher);
            if (IsEcho(launcher, l.Vis)) return;
            Frame b = GetFrame(biz);
            if (!launcherSizing && Math.Abs(l.Vis.Top - b.Vis.Top) <= 1 && Math.Abs(l.Vis.Left - (b.Vis.Right + gap)) <= 1) {
                // Not moved, just a new height: its panels folded or opened.
                // A repeat of the same height is skipped (see the Game
                // Assistant's, above).
                if (l.H != naturalHeight) {
                    naturalHeight = l.H;
                    FitContent();
                }
                return;
            }
            FollowLauncher(l);
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
        bizPid = pid;
        RefreshDocked();
        eventProc = OnEvent;
        IntPtr sizeHook = SetWinEventHook(EVENT_SYSTEM_MOVESIZESTART, EVENT_SYSTEM_MOVESIZEEND, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        IntPtr moveHook = SetWinEventHook(EVENT_OBJECT_LOCATIONCHANGE, EVENT_OBJECT_NAMECHANGE, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        IntPtr showHook = SetWinEventHook(EVENT_OBJECT_DESTROY, EVENT_OBJECT_HIDE, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        IntPtr scrollHook = SetWinEventHook(EVENT_OBJECT_VALUECHANGE, EVENT_OBJECT_VALUECHANGE, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        // Once a second: are both windows still open? (And the docked ones
        // looked up again, in case an event was missed.)
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
                } else {
                    RefreshDocked();
                }
                continue;
            }
            TranslateMessage(ref msg);
            DispatchMessage(ref msg);
        }
        UnhookWinEvent(sizeHook);
        UnhookWinEvent(moveHook);
        UnhookWinEvent(showHook);
        UnhookWinEvent(scrollHook);
    }
}
"@

[AutocrystalDock]::Run([IntPtr]$Hwnd, $GameAspect, $Gap, -not $NoDock)
