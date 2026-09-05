using System.Globalization;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
namespace MacTree.Windows;
public sealed class Treemap : FrameworkElement
{
    private Entry[] entries = [];
    private readonly List<(Rect Box, Entry Node)> tiles = [];
    public Action<Entry>? Navigate { get; set; }
    public void Show(Entry node) { entries = node.Children.Where(x => x.Bytes > 0).ToArray(); InvalidateVisual(); }
    public Treemap()
    {
        ClipToBounds = true;
        MouseMove += (_, e) => { var node = Hit(e.GetPosition(this)); ToolTip = node == null ? null : $"{node.Name}\n{node.Size}\n{node.Path}"; };
        MouseDown += (_, e) => { if (e.ChangedButton == MouseButton.Left && e.ClickCount == 2 && Hit(e.GetPosition(this)) is { IsDirectory: true } n) Navigate?.Invoke(n); };
    }
    private Entry? Hit(Point point) => tiles.FirstOrDefault(x => x.Box.Contains(point)).Node;
    protected override void OnRender(DrawingContext dc)
    {
        base.OnRender(dc); tiles.Clear();
        dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(226, 232, 240)), null, new Rect(RenderSize));
        if (entries.Length == 0 || ActualWidth < 2 || ActualHeight < 2) return;
        var prefix = new double[entries.Length + 1];
        for (int i = 0; i < entries.Length; i++) prefix[i + 1] = prefix[i] + entries[i].Bytes;
        Draw(0, entries.Length, new Rect(0, 0, ActualWidth, ActualHeight));
        void Draw(int start, int end, Rect rect)
        {
            if (rect.Width < 1 || rect.Height < 1) return;
            if (end - start == 1)
            {
                var node = entries[start];
                var box = new Rect(rect.X + 1, rect.Y + 1, Math.Max(0, rect.Width - 2), Math.Max(0, rect.Height - 2));
                uint hash = 2166136261; foreach (char c in node.Kind) hash = unchecked((hash ^ c) * 16777619);
                Color[] colors = [Color.FromRgb(14, 165, 168), Color.FromRgb(59, 130, 246), Color.FromRgb(139, 92, 246), Color.FromRgb(217, 119, 6), Color.FromRgb(22, 163, 74)];
                dc.DrawRoundedRectangle(new SolidColorBrush(colors[hash % (uint)colors.Length]), null, box, 4, 4);
                tiles.Add((box, node));
                if (box.Width > 65 && box.Height > 38)
                {
                    var text = new FormattedText(node.Name + "\n" + node.Size, CultureInfo.CurrentCulture, FlowDirection.LeftToRight,
                        new Typeface("Segoe UI"), 12, Brushes.White, VisualTreeHelper.GetDpi(this).PixelsPerDip)
                        { MaxTextWidth = box.Width - 12, MaxTextHeight = box.Height - 8, Trimming = TextTrimming.CharacterEllipsis };
                    dc.DrawText(text, new Point(box.X + 6, box.Y + 4));
                }
                return;
            }
            double total = prefix[end] - prefix[start];
            double half = prefix[start] + total / 2;
            int split = Array.BinarySearch(prefix, start + 1, end - start - 1, half);
            if (split < 0) split = ~split;
            split = Math.Clamp(split, start + 1, end - 1);
            double ratio = (prefix[split] - prefix[start]) / total;
            if (rect.Width >= rect.Height)
            {
                double w = rect.Width * ratio;
                Draw(start, split, new Rect(rect.X, rect.Y, w, rect.Height));
                Draw(split, end, new Rect(rect.X + w, rect.Y, rect.Width - w, rect.Height));
            }
            else
            {
                double h = rect.Height * ratio;
                Draw(start, split, new Rect(rect.X, rect.Y, rect.Width, h));
                Draw(split, end, new Rect(rect.X, rect.Y + h, rect.Width, rect.Height - h));
            }
        }
    }
    protected override void OnRenderSizeChanged(SizeChangedInfo sizeInfo) { base.OnRenderSizeChanged(sizeInfo); InvalidateVisual(); }
}
