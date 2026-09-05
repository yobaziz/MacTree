using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
namespace MacTree.Windows;
public sealed class Treemap : FrameworkElement
{
    private Entry? root, selected;
    private readonly List<(Rect Box, Entry Node)> tiles = [];
    public Action<Entry>? Navigate { get; set; }
    public Action<Entry>? Select { get; set; }
    public Action<string>? Hover { get; set; }
    internal int TileCount => tiles.Count;
    internal int FileTileCount => tiles.Count(x => !x.Node.IsDirectory);
    private static readonly Brush BackgroundBrush = Brush("#111D30"), FolderBrush = Brush("#273A53");
    private static Brush Brush(string color) { var b = (SolidColorBrush)new BrushConverter().ConvertFromString(color)!; b.Freeze(); return b; }
    private static readonly Brush Game = Brush("#18A7A0"), Apps = Brush("#5588E8"), Media = Brush("#AD78DF"), Archives = Brush("#D4993A"), Other = Brush("#73869C");
    private static Brush ColorFor(Entry n)
    {
        string ext = System.IO.Path.GetExtension(n.Name).ToLowerInvariant();
        return ext switch
        {
            ".pak" or ".vpk" or ".pck" or ".bundle" or ".assets" or ".wad" => Game,
            ".exe" or ".dll" or ".sys" or ".cs" or ".js" or ".py" => Apps,
            ".mp4" or ".mkv" or ".mp3" or ".wav" or ".png" or ".jpg" or ".dds" or ".ogg" => Media,
            ".zip" or ".7z" or ".rar" or ".iso" or ".cab" => Archives,
            _ => Other
        };
    }
    public void Show(Entry node) { root = node; selected = null; InvalidateVisual(); }
    public void Highlight(Entry? node) { selected = node; InvalidateVisual(); }
    public Treemap()
    {
        ClipToBounds = true;
        MouseMove += (_, e) => {
            var n = Hit(e.GetPosition(this));
            ToolTip = n == null ? null : $"{n.Path}\n{n.Size} · {n.Files:N0} files";
            Hover?.Invoke(n == null ? "Areas show logical size; colors show file type." : $"{n.Path}  ·  {n.Size}  ·  {n.Files:N0} files");
        };
        MouseDown += (_, e) => {
            if (e.ChangedButton != MouseButton.Left || Hit(e.GetPosition(this)) is not { } n) return;
            if (e.ClickCount == 2 && n.IsDirectory) Navigate?.Invoke(n);
            else { selected = n; Select?.Invoke(n); InvalidateVisual(); }
        };
    }
    // Child tiles are appended after parents: prefer the deepest visible hit.
    private Entry? Hit(Point point) { for (int i = tiles.Count - 1; i >= 0; i--) if (tiles[i].Box.Contains(point)) return tiles[i].Node; return null; }
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); tiles.Clear(); dc.DrawRectangle(BackgroundBrush, null, new Rect(RenderSize));
        if (ActualWidth < 2 || ActualHeight < 2) return;
        if (root == null || root.Bytes == 0)
        { Label("Scan a folder to see its contents here.", new Rect(12, 12, ActualWidth - 12, ActualHeight - 12), Brushes.LightSlateGray); return; }
        RenderChildren(root, new Rect(0, 0, ActualWidth, ActualHeight), 0);
        // A folder selection outlines its entire represented region.
        foreach (var tile in tiles.Where(x => ReferenceEquals(x.Node, selected)))
            dc.DrawRectangle(null, new Pen(Brushes.White, 2), tile.Box);
        void Label(string text, Rect box, Brush color)
        {
            if (box.Width < 35 || box.Height < 16) return;
            var ft = new FormattedText(text, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 12, color, VisualTreeHelper.GetDpi(this).PixelsPerDip)
            { MaxTextWidth = Math.Max(1, box.Width - 10), MaxTextHeight = Math.Max(1, box.Height - 4), Trimming = TextTrimming.CharacterEllipsis };
            dc.DrawText(ft, new Point(box.X + 5, box.Y + 2));
        }
        void RenderChildren(Entry folder, Rect area, int depth)
        {
            var list = folder.Children.Where(x => x.Bytes > 0).ToArray();
            if (list.Length == 0) return;
            // Bound drawing cost. Preserve every byte by aggregating the small tail.
            if (list.Length > 400)
            {
                var tail = list.Skip(399).ToArray();
                list = list.Take(399).Append(new Entry { Name = $"{tail.Length:N0} smaller items", Path = folder.Path,
                    Bytes = tail.Sum(x => x.Bytes), Files = tail.Sum(x => x.Files), Parent = folder }).ToArray();
            }
            double[] prefix = new double[list.Length + 1];
            for (int i = 0; i < list.Length; i++) prefix[i + 1] = prefix[i] + list[i].Bytes;
            Split(0, list.Length, area);
            void Split(int start, int end, Rect rect)
            {
                if (rect.Width < 1 || rect.Height < 1) return;
                if (end - start == 1)
                {
                    var n = list[start]; var box = new Rect(rect.X + 1, rect.Y + 1, Math.Max(0, rect.Width - 2), Math.Max(0, rect.Height - 2));
                    dc.DrawRectangle(n.IsDirectory ? FolderBrush : ColorFor(n), null, box); tiles.Add((box, n));
                    bool descend = n.IsDirectory && depth < 8 && box.Width > 95 && box.Height > 65 && tiles.Count < 6000;
                    if (descend)
                    {
                        var content = n;
                        string title = n.Name;
                        // Do not spend a header row on every single-child container.
                        for (int chain = 0; chain < 32; chain++)
                        {
                            var positive = content.Children.Where(x => x.Bytes > 0).Take(2).ToArray();
                            if (positive.Length != 1 || !positive[0].IsDirectory) break;
                            content = positive[0]; title += " / " + content.Name;
                        }
                        Label(title + "  ·  " + n.Size, new Rect(box.X + 2, box.Y + 2, box.Width - 4, 22), Brushes.White);
                        RenderChildren(content, new Rect(box.X + 3, box.Y + 26, box.Width - 6, box.Height - 29), depth + 1);
                    }
                    else Label(n.Name + "\n" + n.Size, box, Brushes.White);
                    return;
                }
                double total = prefix[end] - prefix[start], half = prefix[start] + total / 2;
                int split = Array.BinarySearch(prefix, start + 1, end - start - 1, half);
                if (split < 0) split = ~split;
                split = Math.Clamp(split, start + 1, end - 1);
                // Choose the closest weight boundary to avoid long skinny strips.
                if (split > start + 1 && Math.Abs(prefix[split - 1] - half) < Math.Abs(prefix[split] - half)) split--;
                double ratio = (prefix[split] - prefix[start]) / total;
                if (rect.Width >= rect.Height)
                { double w = rect.Width * ratio; Split(start, split, new Rect(rect.X, rect.Y, w, rect.Height)); Split(split, end, new Rect(rect.X + w, rect.Y, rect.Width - w, rect.Height)); }
                else
                { double h = rect.Height * ratio; Split(start, split, new Rect(rect.X, rect.Y, rect.Width, h)); Split(split, end, new Rect(rect.X, rect.Y + h, rect.Width, rect.Height - h)); }
            }
        }
    }
    protected override void OnRenderSizeChanged(SizeChangedInfo info) { base.OnRenderSizeChanged(info); InvalidateVisual(); }
}
