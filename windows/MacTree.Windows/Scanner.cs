using System.Diagnostics;
using System.IO;
namespace MacTree.Windows;

public sealed class Entry
{
    public required string Name { get; init; }
    public required string Path { get; init; }
    public bool IsDirectory { get; init; }
    public Entry? Parent { get; init; }
    public List<Entry> Children { get; } = [];
    public long Bytes { get; set; }
    public long Files { get; set; }
    public bool Incomplete { get; set; }
    public string Size => Format(Bytes);
    public string Kind => IsDirectory ? "Folder" : System.IO.Path.GetExtension(Name);
    public string Label => $"{Name}   {Size}{(Incomplete ? "  [partial]" : "")}";
    public static string Format(long bytes)
    {
        string[] units = ["B", "KiB", "MiB", "GiB", "TiB"];
        double n = bytes; int i = 0;
        while (n >= 1024 && i < units.Length - 1) { n /= 1024; i++; }
        return $"{n:0.##} {units[i]}";
    }
}
public record ScanProgress(long Files, string Path);
public record ScanResult(Entry Root, long Skipped, TimeSpan Elapsed);
public interface IScanner
{
    ScanResult Scan(string path, CancellationToken token, IProgress<ScanProgress>? progress = null);
}
// Baseline enumerator. A future NTFS backend can implement IScanner without changing the UI.
public sealed class DirectoryScanner : IScanner
{
    public ScanResult Scan(string path, CancellationToken token, IProgress<ScanProgress>? progress = null)
    {
        var clock = Stopwatch.StartNew();
        var rootInfo = new DirectoryInfo(System.IO.Path.GetFullPath(path));
        if (!rootInfo.Exists) throw new DirectoryNotFoundException(path);
        if ((rootInfo.Attributes & FileAttributes.ReparsePoint) != 0)
            throw new IOException("Choose the original folder instead of a junction or symbolic link.");
        var root = new Entry { Name = rootInfo.Name, Path = rootInfo.FullName, IsDirectory = true };
        var pending = new Stack<Entry>(); pending.Push(root);
        var directories = new List<Entry>(); long skipped = 0, files = 0;
        long lastReport = 0;
        var options = new EnumerationOptions { RecurseSubdirectories = false, IgnoreInaccessible = false, AttributesToSkip = 0 };
        while (pending.TryPop(out var folder))
        {
            token.ThrowIfCancellationRequested(); directories.Add(folder);
            try
            {
                foreach (var info in new DirectoryInfo(folder.Path).EnumerateFileSystemInfos("*", options))
                {
                    token.ThrowIfCancellationRequested();
                    try
                    {
                        if ((info.Attributes & FileAttributes.ReparsePoint) != 0) { skipped++; folder.Incomplete = true; continue; }
                        bool isDir = (info.Attributes & FileAttributes.Directory) != 0;
                        var node = new Entry { Name = info.Name, Path = info.FullName, IsDirectory = isDir, Parent = folder,
                            Bytes = isDir ? 0 : ((FileInfo)info).Length, Files = isDir ? 0 : 1 };
                        folder.Children.Add(node);
                        if (isDir) pending.Push(node);
                        else { folder.Bytes += node.Bytes; folder.Files++; files++; }
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    { skipped++; folder.Incomplete = true; }
                    if (clock.ElapsedMilliseconds - lastReport >= 150)
                    { progress?.Report(new(files, folder.Path)); lastReport = clock.ElapsedMilliseconds; }
                }
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                if (folder == root) throw;
                skipped++; folder.Incomplete = true;
            }
        }
        for (int i = directories.Count - 1; i >= 0; i--)
        {
            token.ThrowIfCancellationRequested();
            var folder = directories[i];
            folder.Children.Sort((a, b) => { int n = b.Bytes.CompareTo(a.Bytes); return n != 0 ? n : StringComparer.OrdinalIgnoreCase.Compare(a.Name, b.Name); });
            if (folder.Parent is { } parent)
            { parent.Bytes += folder.Bytes; parent.Files += folder.Files; parent.Incomplete |= folder.Incomplete; }
        }
        return new(root, skipped, clock.Elapsed);
    }
}
