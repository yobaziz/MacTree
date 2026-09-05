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
        var window = new MainWindow();
        if (e.Args.Contains("--ui-test"))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            window.Loaded += (_, _) => window.Dispatcher.BeginInvoke(System.Windows.Threading.DispatcherPriority.ApplicationIdle, new Action(() => {
                try { window.RunUiChecks(); File.WriteAllText("ui-test-success.txt", "PASS"); Shutdown(0); }
                catch (Exception ex) { File.WriteAllText("ui-test-error.txt", ex.ToString()); Shutdown(1); }
            }));
        }
        window.Show();
    }
}
