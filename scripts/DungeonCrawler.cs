using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Windows.Forms;

[assembly: AssemblyTitle("Dungeon Crawl")]
[assembly: AssemblyProduct("Dungeon Crawl")]
[assembly: AssemblyDescription("Local Dungeon Crawl launcher and GPU readiness tray")]
[assembly: AssemblyVersion("0.5.0.0")]
[assembly: AssemblyFileVersion("0.5.0.0")]

internal static class DungeonCrawler {
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

    [STAThread]
    private static int Main(string[] args) {
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string script = Path.Combine(root, "scripts", "dungeon-tray.ps1");
        try {
            SetCurrentProcessExplicitAppUserModelID("PopeKael.DungeonCrawler");
            if (!File.Exists(script)) throw new FileNotFoundException("Keep DungeonCrawler.exe in the project folder alongside scripts, assets and config.", script);
            Directory.SetCurrentDirectory(root);
            // Applies only to this executable and its children, never user/machine policy.
            Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass", EnvironmentVariableTarget.Process);
            using (Runspace runspace = RunspaceFactory.CreateRunspace()) {
                runspace.ApartmentState = ApartmentState.STA;
                runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                runspace.Open();
                using (PowerShell host = PowerShell.Create()) {
                    host.Runspace = runspace;
                    host.AddCommand(script);
                    foreach (string arg in args) {
                        if (arg == "--status") host.AddParameter("ShowStatus", true);
                        else if (arg == "--no-auto-start") host.AddParameter("NoAutoStart", true);
                        else throw new ArgumentException("Supported options: --status, --no-auto-start");
                    }
                    host.Invoke();
                    if (host.HadErrors) throw new InvalidOperationException(host.Streams.Error[0].ToString());
                }
            }
            return 0;
        } catch (Exception error) {
            try {
                Directory.CreateDirectory(Path.Combine(root, "logs"));
                File.AppendAllText(Path.Combine(root, "logs", "launcher-host.log"), DateTime.UtcNow.ToString("o") + " " + error + Environment.NewLine);
            } catch { }
            MessageBox.Show(error.Message, "Dungeon Crawl launcher", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }
}
