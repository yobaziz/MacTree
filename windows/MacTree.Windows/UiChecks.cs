using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace MacTree.Windows;
public partial class MainWindow
{
    internal void RunUiChecks()
    {
        Entry Dir(string name, Entry? parent = null)
        {
            var n = new Entry { Name = name, Path = parent == null ? @"C:\" : parent.Path.TrimEnd('\\') + "\\" + name, IsDirectory = true, Parent = parent };
            parent?.Children.Add(n); return n;
        }
        void File(Entry parent, string name, long gib)
        {
            long bytes = gib * 1024 * 1024 * 1024;
            parent.Children.Add(new Entry { Name = name, Path = parent.Path + "\\" + name, Bytes = bytes, Files = 1, Parent = parent });
            for (Entry? n = parent; n != null; n = n.Parent) { n.Bytes += bytes; n.Files++; }
        }
        var root = Dir("C:"); var programs = Dir("Program Files (x86)", root);
        var steam = Dir("Steam", programs); var apps = Dir("steamapps", steam); var common = Dir("common", apps);
        var cyber = Dir("Cyberpunk 2077", common); File(cyber, "content.pak", 64); File(cyber, "textures.dds", 18); File(cyber, "game.exe", 2);
        var witcher = Dir("The Witcher 3", common); File(witcher, "world.bundle", 38); File(witcher, "movies.mp4", 12);
        var otherGame = Dir("Hades II", common); File(otherGame, "data.pck", 14); File(otherGame, "music.ogg", 3);
        var microsoft = Dir("Microsoft", programs); File(microsoft, "runtime.dll", 9);
        var users = Dir("Users", root); File(users, "backup.zip", 20); File(users, "video.mkv", 12);
        var system = Dir("Windows", root); File(system, "system.dll", 24);
        void Sort(Entry n) { foreach (var c in n.Children.Where(x => x.IsDirectory)) Sort(c); n.Children.Sort((a, b) => b.Bytes.CompareTo(a.Bytes)); }
        Sort(root);
        LoadResult(new(root, 0, TimeSpan.FromSeconds(2)));
        Require(root.IsExpanded && root.IsSelected, "Root must open automatically");
        Map.Navigate!(common); UpdateLayout();
        Require(ReferenceEquals(current, common) && common.IsSelected && steam.IsExpanded && programs.IsExpanded, "Map navigation expands/selects matching tree path");
        var rootItem = (TreeViewItem?)Tree.ItemContainerGenerator.ContainerFromItem(root);
        Require(rootItem != null && rootItem.IsExpanded, "Expanded root container must render");
        rootItem!.IsSelected = true; UpdateLayout();
        Require(ReferenceEquals(current, root), "Tree selection must update file list/map");
        ShowFolder(programs); UpdateLayout();
        Location.Text = @"C:\";
        Summary.Text = $"{root.Size} logical  ·  {root.Files:N0} files  ·  Demo fixture for UI validation";
        Status.Text = "UI test fixture · Standard folder scanner · Logical sizes";
        Capture("ui-programs.png");
        Require(Map.TileCount >= 12 && Map.FileTileCount >= 5, "Map must show nested contents, not one Steam block");
        ShowFolder(common); UpdateLayout(); Capture("ui-games.png");
        Require(Map.FileTileCount >= 7, "Game folders must expose file-type tiles");
        GoUp(this, new RoutedEventArgs());
        Require(ReferenceEquals(current, apps) && apps.IsSelected, "Up must synchronize tree");
    }
    private static void Require(bool condition, string message) { if (!condition) throw new Exception(message); }
    private void Capture(string name)
    {
        UpdateLayout();
        var bitmap = new RenderTargetBitmap((int)ActualWidth, (int)ActualHeight, 96, 96, PixelFormats.Pbgra32);
        bitmap.Render(this);
        var encoder = new PngBitmapEncoder(); encoder.Frames.Add(BitmapFrame.Create(bitmap));
        using var stream = File.Create(name); encoder.Save(stream);
    }
}
