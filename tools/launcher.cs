using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Runtime.InteropServices;

// Tiny launcher: starts tray.ps1 (next to this exe) with no window. Build: see tools/build-exe.bat
static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBox(IntPtr h, string text, string caption, uint type);

    static string dir = AppDomain.CurrentDomain.BaseDirectory;

    static void Log(string m)
    {
        try { File.AppendAllText(Path.Combine(dir, "launcher-log.txt"), DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + m + "\r\n"); } catch { }
    }

    static bool AlreadyRunning()
    {
        try { Mutex m = Mutex.OpenExisting(@"Local\DisplayModesTray"); m.Close(); return true; }
        catch { return false; }
    }

    // ends any PowerShell that is running tray.ps1
    static void StopOld()
    {
        try
        {
            var psi = new ProcessStartInfo();
            psi.FileName = "powershell.exe";
            psi.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -Command \"Get-CimInstance Win32_Process -Filter \\\"Name='powershell.exe'\\\" | Where-Object { $_.CommandLine -like '*tray.ps1*' -and $_.ProcessId -ne $PID } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }\"";
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            Process p = Process.Start(psi); p.WaitForExit(10000);
        }
        catch (Exception ex) { Log("stop failed: " + ex.Message); }
    }

    [STAThread]
    static int Main(string[] args)
    {
        string script = Path.Combine(dir, "tray.ps1");
        Log("start, folder " + dir);
        if (!File.Exists(script))
        {
            Log("tray.ps1 missing");
            MessageBox(IntPtr.Zero, "tray.ps1 was not found next to this program:\n" + dir, "Display modes", 0x10);
            return 1;
        }
        if (AlreadyRunning())
        {
            Log("already running");
            // MB_YESNO | MB_ICONQUESTION; IDYES = 6
            int r = MessageBox(IntPtr.Zero, "Display modes is already running, but its icon may be hidden or stuck.\n\nRestart it now?", "Display modes", 0x24);
            if (r != 6) return 0;
            StopOld();
            for (int i = 0; i < 20 && AlreadyRunning(); i++) Thread.Sleep(250);
            if (AlreadyRunning())
            {
                Log("old copy did not stop");
                MessageBox(IntPtr.Zero, "Could not stop the running copy. End the PowerShell process in Task Manager (Details tab) and try again.", "Display modes", 0x10);
                return 4;
            }
            Log("old copy stopped");
        }
        try
        {
            // always use the 64-bit PowerShell, even if this launcher ends up running as a 32-bit process
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string ps = "powershell.exe";
            if (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess)
            {
                string sysnative = Path.Combine(win, "sysnative", "WindowsPowerShell", "v1.0", "powershell.exe");
                if (File.Exists(sysnative)) ps = sysnative;
            }
            var psi = new ProcessStartInfo();
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Log("starting " + ps);
            Process p = Process.Start(psi);
            // the tray keeps running; if PowerShell ends within a few seconds something went wrong
            if (p.WaitForExit(4000))
            {
                Log("powershell exited early, code " + p.ExitCode);
                MessageBox(IntPtr.Zero, "The tray app stopped right after starting (code " + p.ExitCode + ").\nThe reason is in tray-log.txt in:\n" + dir, "Display modes", 0x10);
                return 3;
            }
            Log("running");
            return 0;
        }
        catch (Exception ex)
        {
            Log("failed: " + ex.Message);
            MessageBox(IntPtr.Zero, "Could not start the tray app:\n" + ex.Message, "Display modes", 0x10);
            return 2;
        }
    }
}
