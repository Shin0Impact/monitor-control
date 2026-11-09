using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;

// Tiny launcher: starts tray.ps1 (next to this exe) with no window. Build: see tools/build-exe.bat
static class Launcher
{
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBox(IntPtr h, string text, string caption, uint type);

    [STAThread]
    static int Main(string[] args)
    {
        string dir = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(dir, "tray.ps1");
        if (!File.Exists(script))
        {
            MessageBox(IntPtr.Zero, "tray.ps1 was not found next to this program:\n" + dir, "Display modes", 0x10);
            return 1;
        }
        try
        {
            var psi = new ProcessStartInfo();
            // always use the 64-bit PowerShell, even if this launcher ends up running as a 32-bit process
            string win = Environment.GetFolderPath(Environment.SpecialFolder.Windows);
            string ps = "powershell.exe";
            if (Environment.Is64BitOperatingSystem && !Environment.Is64BitProcess)
            {
                string sysnative = Path.Combine(win, "sysnative", "WindowsPowerShell", "v1.0", "powershell.exe");
                if (File.Exists(sysnative)) ps = sysnative;
            }
            psi.FileName = ps;
            psi.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"" + script + "\"";
            psi.WorkingDirectory = dir;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox(IntPtr.Zero, "Could not start the tray app:\n" + ex.Message, "Display modes", 0x10);
            return 2;
        }
    }
}
