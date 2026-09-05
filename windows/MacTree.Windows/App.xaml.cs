using System.IO;
using System.Windows;
namespace MacTree.Windows;
public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        if (e.Args.Contains("--self-test"))
        {
            try { ScannerChecks.Run(); Shutdown(0); }
            catch (Exception ex) { File.WriteAllText("self-test-error.txt", ex.ToString()); Shutdown(1); }
            return;
        }
        new MainWindow().Show();
    }
}
