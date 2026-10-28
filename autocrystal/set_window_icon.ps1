param(
    # Window to put the icon on. launcher.lua passes the value
    # forms.newform() returned, which is that form's real Win32 handle.
    [Parameter(Mandatory = $true)][long]$Hwnd,

    # Any image System.Drawing can load (PNG with transparency works).
    # Non-square images are centered on a transparent square, not stretched.
    [Parameter(Mandatory = $true)][string]$ImagePath,

    # Safety check: the icon is only ever (re)applied while the window's
    # title still contains this - so if the window closes and Windows
    # hands the same handle value to some unrelated window, it's left alone.
    [string]$TitleContains = "autocrystal",

    # The bot's other windows (the settings popups, Encounter Stats), by
    # exact title, separated by ";". They come and go while the launcher
    # is open; each gets the same icon the moment it appears.
    [string]$AlsoTitles = ""
)

# ===================================================================
#  Why this exists
#
#  BizHawk's forms.newform() always gives its windows the stock Windows
#  application icon, and forms.setproperty() can't replace it - it can
#  only convert values to simple types (numbers, text, colors), not an
#  Icon. Windows itself doesn't care who sets a window's icon, though:
#  WM_SETICON works from any process. So this sets it from outside.
#
#  It has to keep running for as long as the launcher is open - Windows
#  destroys an icon when the process that created it exits, and the
#  windows would go back to showing nothing. Windows' own "window shown"
#  events for BizHawk's process tell it when one of the other windows
#  opens; once a second it re-applies the icon anywhere something put a
#  different one back, and it exits on its own once the launcher is gone.
# ===================================================================

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class AutocrystalIcons {
    [StructLayout(LayoutKind.Sequential)] public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public int ptX, ptY; }
    public delegate void WinEventProc(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint min, uint max, IntPtr module, WinEventProc proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hook);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG msg, IntPtr hWnd, uint min, uint max);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG msg);
    [DllImport("user32.dll")] static extern UIntPtr SetTimer(IntPtr hWnd, UIntPtr id, uint ms, IntPtr proc);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hWnd, uint flags);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam, int flags, int timeoutMs, out IntPtr result);

    const uint EVENT_OBJECT_SHOW = 0x8002, WINEVENT_OUTOFCONTEXT = 0, GA_ROOT = 2, WM_TIMER = 0x0113;
    const int WM_SETICON = 0x0080, WM_GETICON = 0x007F;
    static readonly IntPtr ICON_SMALL = IntPtr.Zero, ICON_BIG = (IntPtr)1;
    // Don't hang on a window if BizHawk is busy - give up after 1s and try
    // again on the next check.
    const int SMTO_ABORTIFHUNG = 0x0002, SEND_TIMEOUT_MS = 1000;

    static IntPtr launcher, smallIcon, bigIcon;
    static uint pid;
    static string launcherTitleContains;
    static HashSet<string> otherTitles;
    static readonly HashSet<IntPtr> others = new HashSet<IntPtr>();
    static WinEventProc eventProc; // kept in a field so it's never garbage-collected

    static string Title(IntPtr h) {
        StringBuilder sb = new StringBuilder(256);
        GetWindowText(h, sb, sb.Capacity);
        return sb.ToString();
    }

    static IntPtr Send(IntPtr h, int msg, IntPtr wParam, IntPtr lParam) {
        IntPtr result;
        SendMessageTimeout(h, msg, wParam, lParam, SMTO_ABORTIFHUNG, SEND_TIMEOUT_MS, out result);
        return result;
    }

    static void Apply(IntPtr h) {
        Send(h, WM_SETICON, ICON_SMALL, smallIcon);
        Send(h, WM_SETICON, ICON_BIG, bigIcon);
    }

    // BizHawk only sets its stock icon once, when a form is created, but
    // WinForms re-sends its own Icon any time that property gets touched -
    // put ours back if that ever happens.
    static void Refresh(IntPtr h) {
        if (Send(h, WM_GETICON, ICON_SMALL, IntPtr.Zero) != smallIcon) Apply(h);
    }

    static bool LauncherOpen() {
        return IsWindow(launcher) && Title(launcher).Contains(launcherTitleContains);
    }

    // One of the bot's other windows: a top-level window of BizHawk's own
    // process with one of the given titles.
    static bool IsOther(IntPtr h) {
        if (h == launcher || GetAncestor(h, GA_ROOT) != h) return false;
        uint p;
        GetWindowThreadProcessId(h, out p);
        return p == pid && otherTitles.Contains(Title(h));
    }

    static void Found(IntPtr h) {
        if (!IsOther(h)) return;
        others.Add(h);
        Apply(h);
    }

    static void OnEvent(IntPtr hook, uint evt, IntPtr hwnd, int idObject, int idChild, uint thread, uint time) {
        if (idObject == 0 && idChild == 0) Found(hwnd); // the window itself, not a part of it
    }

    public static void Run(IntPtr launcherHwnd, IntPtr small, IntPtr big, string titleContains, string alsoTitles) {
        launcher = launcherHwnd; smallIcon = small; bigIcon = big; launcherTitleContains = titleContains;
        otherTitles = new HashSet<string>(alsoTitles.Split(new[] { ';' }, StringSplitOptions.RemoveEmptyEntries));
        if (!LauncherOpen()) return;
        GetWindowThreadProcessId(launcher, out pid);
        Apply(launcher);

        IntPtr hook = IntPtr.Zero;
        if (otherTitles.Count > 0) {
            // Any that are already open, then each one as it's shown.
            EnumWindows(delegate(IntPtr h, IntPtr l) { Found(h); return true; }, IntPtr.Zero);
            eventProc = OnEvent;
            hook = SetWinEventHook(EVENT_OBJECT_SHOW, EVENT_OBJECT_SHOW, IntPtr.Zero, eventProc, pid, 0, WINEVENT_OUTOFCONTEXT);
        }
        SetTimer(IntPtr.Zero, UIntPtr.Zero, 1000, IntPtr.Zero);

        // The events arrive through this thread's message queue.
        MSG msg;
        while (GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) {
            if (msg.message != WM_TIMER) { DispatchMessage(ref msg); continue; }
            if (!LauncherOpen()) break;
            Refresh(launcher);
            // Closed ones drop out; a handle that now belongs to some
            // unrelated window fails the title check and is left alone.
            others.RemoveWhere(h => !IsWindow(h) || !IsOther(h));
            foreach (IntPtr h in others) Refresh(h);
        }
        if (hook != IntPtr.Zero) UnhookWinEvent(hook);
    }
}
"@
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class WindowIconNative {
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}
"@

# DPI-aware, so SystemInformation below reports the icon sizes Windows
# actually draws at (e.g. 24px title-bar icons at 150% scaling) instead
# of 16px that would then get blurrily upscaled.
[void][WindowIconNative]::SetProcessDPIAware()

function New-IconHandle([System.Drawing.Image]$Source, [int]$Size) {
    $bitmap = New-Object System.Drawing.Bitmap $Size, $Size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bitmap)
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $scale = [Math]::Min($Size / $Source.Width, $Size / $Source.Height)
    $w = [int][Math]::Round($Source.Width * $scale)
    $h = [int][Math]::Round($Source.Height * $scale)
    $g.DrawImage($Source, [int](($Size - $w) / 2), [int](($Size - $h) / 2), $w, $h)
    $g.Dispose()
    $handle = $bitmap.GetHicon()
    $bitmap.Dispose()
    return $handle
}

# Resolved up front: launcher.lua may pass a path relative to BizHawk's
# working directory, which this process inherits.
$source = [System.Drawing.Image]::FromFile((Resolve-Path -LiteralPath $ImagePath).Path)
$smallIcon = New-IconHandle $source ([System.Windows.Forms.SystemInformation]::SmallIconSize.Width)
$bigIcon = New-IconHandle $source ([System.Windows.Forms.SystemInformation]::IconSize.Width)
$source.Dispose()

try {
    [AutocrystalIcons]::Run([IntPtr]$Hwnd, $smallIcon, $bigIcon, $TitleContains, $AlsoTitles)
} finally {
    [void][WindowIconNative]::DestroyIcon($smallIcon)
    [void][WindowIconNative]::DestroyIcon($bigIcon)
}
