param(
    # Any window of the BizHawk whose Lua Console should be minimized -
    # launcher.lua passes its own window's handle (what forms.newform()
    # returned), so another BizHawk running at the same time is left alone.
    [Parameter(Mandatory = $true)][long]$Hwnd,

    [string]$ConsoleTitle = "Lua Console"
)

# ===================================================================
#  Minimizes BizHawk's Lua Console once, right as launcher.lua starts, so
#  only BizHawk itself and the launcher window stay on screen. BizHawk's
#  Lua API has no way to do this from the script itself.
#
#  The Lua Console is an ordinary top-level window with its own taskbar
#  button, so it's one click to bring back (to read a script error, say).
#  Minimized without activating it, so focus isn't pulled anywhere. Exits
#  right away - restoring it later is left entirely to you.
# ===================================================================

Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class LuaConsoleNative {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int maxCount);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr hWnd, int cmdShow);
    public static List<IntPtr> TopLevelWindows() {
        var all = new List<IntPtr>();
        EnumWindows((h, l) => { all.Add(h); return true; }, IntPtr.Zero);
        return all;
    }
}
"@

# Minimized, but the currently active window stays active.
$SW_SHOWMINNOACTIVE = 7

$bizHawkProcessId = 0
[void][LuaConsoleNative]::GetWindowThreadProcessId([IntPtr]$Hwnd, [ref]$bizHawkProcessId)
if ($bizHawkProcessId -eq 0) { exit }

foreach ($window in [LuaConsoleNative]::TopLevelWindows()) {
    $owner = 0
    [void][LuaConsoleNative]::GetWindowThreadProcessId($window, [ref]$owner)
    if ($owner -ne $bizHawkProcessId -or -not [LuaConsoleNative]::IsWindowVisible($window)) { continue }
    $title = New-Object System.Text.StringBuilder 256
    [void][LuaConsoleNative]::GetWindowText($window, $title, $title.Capacity)
    if ($title.ToString().StartsWith($ConsoleTitle)) {
        # Async: never wait on BizHawk's UI thread, which is busy running
        # the launcher script at this exact moment.
        [void][LuaConsoleNative]::ShowWindowAsync($window, $SW_SHOWMINNOACTIVE)
    }
}
