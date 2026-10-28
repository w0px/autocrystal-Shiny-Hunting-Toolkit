// start.exe - one-click start for autocrystal.
//
// Opens BizHawk with launcher.lua already loaded in its Lua Console (no
// ROM - you pick that in BizHawk as usual), plus the --url_post/--url_get
// flags the Discord notifications need. launcher.lua then starts the
// Discord relays and the other background helpers by itself.
//
// Where it looks for things, first match wins:
//   launcher.lua - autocrystal\launcher.lua next to start.exe, else
//                  bot\launcher.lua (that folder's name before), else
//                  launcher.lua right next to it.
//   BizHawk      - the bundled BizHawk\EmuHawk.exe next to start.exe;
//                  else the copy remembered in start_settings.txt (next to
//                  launcher.lua); else the newest version found in the
//                  usual places; else a file picker. Anything found by
//                  searching/picking is remembered in start_settings.txt.
//
// A real C# program on purpose, not a wrapped script: a small compiled exe
// is far less likely to trip antivirus heuristics than a script-to-exe
// wrapper or an exe that shells out to a hidden PowerShell.
//
// Build: tools\start_exe\build.ps1 (uses the C# compiler that ships with
// Windows' .NET Framework - nothing to install).
//
// "start.exe --dry-run" prints what it would do instead of doing it.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.RegularExpressions;
using System.Windows.Forms;

[assembly: AssemblyTitle("autocrystal")]
[assembly: AssemblyProduct("autocrystal")]
[assembly: AssemblyDescription("Starts BizHawk with the autocrystal launcher loaded")]

static class Start
{
    // Same relay address the hunting modules post to (DISCORD_RELAY_URL).
    const string RelayUrl = "http://127.0.0.1:5000/";

    [STAThread]
    static int Main(string[] args)
    {
        bool dryRun = args.Contains("--dry-run");
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;

        string launcher = FirstExisting(
            Path.Combine(baseDir, "autocrystal", "launcher.lua"),
            Path.Combine(baseDir, "bot", "launcher.lua"),
            Path.Combine(baseDir, "launcher.lua"));
        if (launcher == null)
        {
            Fail("launcher.lua wasn't found next to start.exe (or in its \"autocrystal\" folder).");
            return 1;
        }

        string settingsPath = Path.Combine(Path.GetDirectoryName(launcher), "start_settings.txt");
        Dictionary<string, string> settings = ReadSettings(settingsPath);

        string source;
        string emuHawk = FindBizHawk(baseDir, settings, out source);
        if (emuHawk == null)
        {
            Fail("Couldn't find BizHawk (EmuHawk.exe) - nothing was started.");
            return 1;
        }
        if ((source == "found" || source == "picked") && !dryRun)
        {
            settings["bizhawk"] = emuHawk;
            WriteSettings(settingsPath, settings);
        }

        string arguments = string.Format("--url_post={0} --url_get={0} --lua=\"{1}\"", RelayUrl, launcher);
        bool alreadyRunning = Process.GetProcessesByName("EmuHawk").Length > 0;

        if (dryRun)
        {
            Console.WriteLine("launcher.lua: " + launcher);
            Console.WriteLine("BizHawk:      " + emuHawk + " (" + source + ", version " + BizHawkVersion(emuHawk) + ")");
            Console.WriteLine("Command:      \"" + emuHawk + "\" " + arguments);
            Console.WriteLine("Already running: " + alreadyRunning);
            return 0;
        }

        // Two copies would fight over the relays' ports and the savestate
        // slots.
        if (alreadyRunning)
        {
            DialogResult answer = MessageBox.Show(
                "BizHawk is already running. Start another copy anyway?\n\n" +
                "(To restart the bot inside the open BizHawk, reload launcher.lua in its Lua Console instead.)",
                "autocrystal", MessageBoxButtons.YesNo, MessageBoxIcon.Question);
            if (answer != DialogResult.Yes) return 0;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = emuHawk,
                Arguments = arguments,
                WorkingDirectory = Path.GetDirectoryName(emuHawk),
                UseShellExecute = false,
            });
        }
        catch (Exception e)
        {
            Fail("Couldn't start BizHawk:\n" + e.Message);
            return 1;
        }
        return 0;
    }

    // source: "bundled", "remembered", "found" (searched) or "picked".
    static string FindBizHawk(string baseDir, Dictionary<string, string> settings, out string source)
    {
        string bundled = Path.Combine(baseDir, "BizHawk", "EmuHawk.exe");
        if (File.Exists(bundled)) { source = "bundled"; return bundled; }

        string remembered;
        if (settings.TryGetValue("bizhawk", out remembered) && File.Exists(remembered))
        {
            source = "remembered";
            return remembered;
        }

        string found = SearchForBizHawk(baseDir);
        if (found != null) { source = "found"; return found; }

        using (var dialog = new OpenFileDialog())
        {
            dialog.Title = "Where is BizHawk? Pick EmuHawk.exe";
            dialog.Filter = "EmuHawk.exe|EmuHawk.exe";
            if (dialog.ShowDialog() == DialogResult.OK) { source = "picked"; return dialog.FileName; }
        }
        source = null;
        return null;
    }

    // EmuHawk.exe sits at the top of a BizHawk folder, so only look one
    // level down from each root (plus the root itself) - fast, and enough
    // for every normal "unzipped it somewhere" layout. Newest version wins.
    static string SearchForBizHawk(string baseDir)
    {
        string home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var roots = new List<string> {
            Directory.GetParent(baseDir.TrimEnd('\\')) == null ? null : Directory.GetParent(baseDir.TrimEnd('\\')).FullName,
            Path.Combine(home, "Downloads"),
            Path.Combine(home, "Desktop"),
            Path.Combine(home, "Documents"),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            @"C:\",
        };

        var candidates = new List<string>();
        foreach (string root in roots.Where(r => r != null && Directory.Exists(r)).Distinct())
        {
            candidates.Add(Path.Combine(root, "EmuHawk.exe"));
            try
            {
                candidates.AddRange(Directory.GetDirectories(root).Select(d => Path.Combine(d, "EmuHawk.exe")));
            }
            catch (UnauthorizedAccessException) { }
            catch (IOException) { }
        }
        return candidates
            .Where(File.Exists)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .OrderByDescending(BizHawkVersion)
            .FirstOrDefault();
    }

    // "2.11.1+bdddf4a..." -> 2.11.1; anything unparseable sorts last.
    static Version BizHawkVersion(string exePath)
    {
        string raw = FileVersionInfo.GetVersionInfo(exePath).ProductVersion ?? "";
        Match m = Regex.Match(raw, @"^\d+(\.\d+){1,3}");
        Version v;
        return m.Success && Version.TryParse(m.Value, out v) ? v : new Version(0, 0);
    }

    static string FirstExisting(params string[] paths)
    {
        return paths.FirstOrDefault(File.Exists);
    }

    // start_settings.txt: plain "key=value" lines. Delete it (or a line of
    // it) to have this pick again.
    static Dictionary<string, string> ReadSettings(string path)
    {
        var settings = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (!File.Exists(path)) return settings;
        foreach (string line in File.ReadAllLines(path))
        {
            int eq = line.IndexOf('=');
            if (eq > 0) settings[line.Substring(0, eq).Trim()] = line.Substring(eq + 1).Trim();
        }
        return settings;
    }

    static void WriteSettings(string path, Dictionary<string, string> settings)
    {
        try
        {
            File.WriteAllLines(path, settings.OrderBy(kv => kv.Key).Select(kv => kv.Key + "=" + kv.Value));
        }
        catch (Exception)
        {
            // Only costs a search next time - never worth failing the start.
        }
    }

    static void Fail(string message)
    {
        MessageBox.Show(message, "autocrystal", MessageBoxButtons.OK, MessageBoxIcon.Error);
    }
}
