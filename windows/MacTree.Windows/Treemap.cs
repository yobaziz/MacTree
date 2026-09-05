using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
namespace MacTree.Windows;
// One-level ranked size chart: labels have their own space, independent of byte size.
public sealed class Treemap : FrameworkElement
{
    private Entry? root, selected;
    private readonly List<(Rect Box, Entry Node)> tiles = [];
    public Action<Entry>? Navigate { get; set; }
    public Action<Entry>? Select { get; set; }
    public Action<string>? Hover { get; set; }
    internal int TileCount => tiles.Count;
    internal long RepresentedBytes => tiles.Sum(x => x.Node.Bytes);
    internal Entry? Group => tiles.Select(x => x.Node).FirstOrDefault(x => x.IsGroup);
    private static readonly string[] Palette = ["#38BDF8", "#2DD4BF", "#A78BFA", "#FBBF24", "#FB7185", "#60A5FA", "#94A3B8"];
    private static Brush Brush(string s) { var b = (SolidColorBrush)new BrushConverter().ConvertFromString(s)!; b.Freeze(); return b; }
    public void Show(Entry node) { root = node; selected = null; InvalidateVisual(); }
    public void Highlight(Entry? node) { selected = node; InvalidateVisual(); }
    public Treemap()
    {
        ClipToBounds = true;
        MouseMove += (_, e) => {
            var n = Hit(e.GetPosition(this)); ToolTip = n == null ? null : $"{n.Name}\n{n.Path}\n{n.Size}";
            Hover?.Invoke(n == null ? "Double-click a folder or grouped row to explore." : $"{n.Name} · {n.Size} · {n.Path}");
        };
        MouseDown += (_, e) => {
            if (e.ChangedButton != MouseButton.Left || Hit(e.GetPosition(this)) is not { } n) return;
            if (e.ClickCount == 2 && n.IsDirectory) Navigate?.Invoke(n);
            else { selected = n; Select?.Invoke(n); InvalidateVisual(); }
        };
    }
    private Entry? Hit(Point point) => tiles.FirstOrDefault(x => x.Box.Contains(point)).Node;
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); tiles.Clear();
        double w = ActualWidth, h = ActualHeight;
        dc.DrawRectangle(Brush("#111D30"), null, new Rect(RenderSize));
        if (w < 100 || h < 30) return;
        void Text(string value, double x, double y, double width, Brush color, double size = 13)
        {
            if (width < 1) return;
            var ft = new FormattedText(value, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), size, color, VisualTreeHelper.GetDpi(this).PixelsPerDip)
            { MaxTextWidth = width, MaxLineCount = 1, Trimming = TextTrimming.CharacterEllipsis };
            dc.DrawText(ft, new Point(x, y));
        }
        if (root == null || root.Bytes == 0) { Text("No sized items in this folder. Choose another folder or scan a drive.", 12, 12, w - 24, Brushes.LightSlateGray); return; }
        var entries = root.Children.Where(x => x.Bytes > 0).OrderByDescending(x => x.Bytes).ToArray();
        int capacity = Math.Clamp((int)(h / 38), 2, 10);
        if (entries.Length > capacity)
        {
            var tail = entries.Skip(capacity - 1).ToArray();
            var group = new Entry { Name = $"Other items ({tail.Length:N0}) — double-click to explore", Path = root.Path,
                IsDirectory = true, IsGroup = true, Parent = root, Bytes = tail.Sum(x => x.Bytes), Files = tail.Sum(x => x.Files) };
            group.Children.AddRange(tail);
            entries = entries.Take(capacity - 1).Append(group).ToArray();
        }
        double rowHeight = Math.Min(48, h / Math.Max(1, entries.Length));
        double labelWidth = Math.Max(200, w * 0.42), barX = labelWidth + 20, barWidth = Math.Max(1, w - barX - 170);
        for (int i = 0; i < entries.Length; i++)
        {
            var n = entries[i]; double y = i * rowHeight;
            var box = new Rect(0, y, w, rowHeight - 2); tiles.Add((box, n));
            if (ReferenceEquals(n, selected)) dc.DrawRoundedRectangle(Brush("#263A52"), null, box, 5, 5);
            var color = Brush(Palette[i % Palette.Length]);
            dc.DrawRoundedRectangle(color, null, new Rect(5, y + 12, 4, 17), 2, 2);
            Text(n.Name, 18, y + 7, labelWidth - 22, Brushes.White);
            double share = Math.Clamp((double)n.Bytes / root.Bytes, 0, 1);
            dc.DrawRoundedRectangle(Brush("#25364C"), null, new Rect(barX, y + 12, barWidth, 14), 4, 4);
            dc.DrawRoundedRectangle(color, null, new Rect(barX, y + 12, barWidth * share, 14), 4, 4);
            Text(n.Size, w - 152, y + 7, 95, Brushes.White);
            Text($"{share:P1}", w - 65, y + 8, 63, Brushes.LightSlateGray, 12);
        }
    }
    protected override void OnRenderSizeChanged(SizeChangedInfo info) { base.OnRenderSizeChanged(info); InvalidateVisual(); }
}
