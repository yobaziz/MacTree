using System.IO;
using System.Windows;
using System.Windows.Input;
using Microsoft.Win32;
namespace MacTree.Windows;
public partial class MainWindow : Window
{
    private CancellationTokenSource? cancellation;
    private Entry? current;
    private bool closed;
    public MainWindow()
    {
        InitializeComponent(); Location.Text = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Map.Navigate = ShowFolder;
        Closed += (_, _) => { closed = true; cancellation?.Cancel(); };
    }
    private void ChooseFolder(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog();
        if (dialog.ShowDialog(this) == true) Location.Text = dialog.FolderName;
    }
    private async void StartScan(object sender, RoutedEventArgs e)
    {
        if (cancellation != null) return;
        var source = new CancellationTokenSource(); cancellation = source;
        Scan.IsEnabled = Choose.IsEnabled = Location.IsEnabled = false; Stop.IsEnabled = true;
        Busy.Visibility = Visibility.Visible; Summary.Text = "Scanning…";
        string path = Location.Text;
        var progress = new Progress<ScanProgress>(p => {
            if (cancellation == source && !closed) Status.Text = $"{p.Files:N0} files · {p.Path}";
        });
        try
        {
            var result = await Task.Run(() => new DirectoryScanner().Scan(path, source.Token, progress));
            if (closed || source.IsCancellationRequested) return;
            Tree.ItemsSource = new[] { result.Root }; ShowFolder(result.Root);
            Summary.Text = $"{result.Root.Size} logical · {result.Root.Files:N0} files · {result.Elapsed.TotalSeconds:0.0}s · {result.Skipped:N0} skipped items";
            Status.Text = result.Root.Incomplete ? "Partial scan: unreadable items and links are excluded. Previous totals may differ from physical disk usage." : "Complete · Logical sizes · Standard folder scan";
        }
        catch (OperationCanceledException) { if (!closed) { Summary.Text = "Scan cancelled"; Status.Text = "Previous results retained. Ready to scan again."; } }
        catch (Exception ex) { if (!closed) { Summary.Text = "Could not scan this location"; Status.Text = ex.Message; } }
        finally
        {
            cancellation = null; source.Dispose();
            if (!closed) { Scan.IsEnabled = Choose.IsEnabled = Location.IsEnabled = true; Stop.IsEnabled = false; Busy.Visibility = Visibility.Collapsed; }
        }
    }
    private void StopScan(object sender, RoutedEventArgs e) { cancellation?.Cancel(); Stop.IsEnabled = false; }
    private void ShowFolder(Entry node)
    {
        if (!node.IsDirectory) node = node.Parent ?? node;
        current = node; CurrentPath.Text = node.Path; CurrentPath.ToolTip = node.Path;
        Files.ItemsSource = node.Children; Map.Show(node);
    }
    private void TreeSelected(object sender, RoutedPropertyChangedEventArgs<object> e) { if (e.NewValue is Entry node) ShowFolder(node); }
    private void GoUp(object sender, RoutedEventArgs e) { if (current?.Parent is { } p) ShowFolder(p); }
    private void OpenSelected(object sender, MouseButtonEventArgs e) { if (Files.SelectedItem is Entry { IsDirectory: true } node) ShowFolder(node); }
}
