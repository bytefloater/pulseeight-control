using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Shapes;
using PulseEight.Core;

namespace PulseEightControl;

/// <summary>Small builders so the code-only views stay readable.</summary>
internal static class Ui
{
    public static TextBlock Text(string text, string? style = null, bool secondary = false, bool wrap = false)
    {
        var block = new TextBlock { Text = text, TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap };
        if (style != null) block.Style = (Style)Application.Current.Resources[style];
        if (secondary) block.Opacity = 0.7;
        return block;
    }

    public static Ellipse Dot(Brush fill, double size = 8) => new()
    {
        Width = size, Height = size, Fill = fill, VerticalAlignment = VerticalAlignment.Center,
    };

    public static Rectangle VerticalSeparator() => new()
    {
        Width = 1, Height = 14, Fill = Palette.Separator, Margin = new Thickness(10, 0, 10, 0),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Rectangle HorizontalSeparator() => new()
    {
        Height = 1, Fill = Palette.Separator, HorizontalAlignment = HorizontalAlignment.Stretch,
    };

    /// <summary>A rounded panel holding rows, like a Windows 11 Settings group.</summary>
    public static Border Card(params UIElement[] rows)
    {
        var stack = new StackPanel();
        for (var i = 0; i < rows.Length; i++)
        {
            if (i > 0) stack.Children.Add(HorizontalSeparator());
            stack.Children.Add(rows[i]);
        }
        return new Border
        {
            Background = Palette.Card, BorderBrush = Palette.CardBorder, BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8), Child = stack,
        };
    }

    /// <summary>Every row of every card is at least this tall, whatever it holds, so pages line up.</summary>
    public const double RowMinHeight = 64;

    public static Thickness RowPadding => new(16, 12, 16, 12);

    /// <summary>Label on the left, value or control on the right.</summary>
    public static Grid Row(string label, UIElement value, string? caption = null)
    {
        var grid = new Grid { Padding = RowPadding, ColumnSpacing = 16, MinHeight = RowMinHeight };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var left = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        left.Children.Add(Text(label));
        if (caption != null) left.Children.Add(Text(caption, "CaptionTextBlockStyle", secondary: true, wrap: true));
        grid.Children.Add(left);
        if (value is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn((FrameworkElement)value, 1);
        grid.Children.Add(value);
        return grid;
    }

    public static Grid Row(string label, string value)
    {
        var text = Text(value, secondary: true);
        text.IsTextSelectionEnabled = true;
        text.TextAlignment = TextAlignment.Right;
        text.TextWrapping = TextWrapping.Wrap;
        text.MaxWidth = 320;
        return Row(label, text);
    }

    /// <summary>A tick (in good order) or a warning triangle, coloured to match, for a line that reports health.</summary>
    public static FontIcon HealthGlyph(bool ok)
    {
        var glyph = new FontIcon
        {
            Glyph = ok ? "" : "", FontSize = 16, VerticalAlignment = VerticalAlignment.Center,
            Foreground = Palette.Status(ok ? 0 : 2),
        };
        ToolTipService.SetToolTip(glyph, Loc.T(ok ? "health.good" : "health.attention"));
        return glyph;
    }

    /// <summary>A row's value with a health glyph in front of it.</summary>
    public static Grid HealthRow(string label, string value, bool ok)
    {
        var text = Text(value, secondary: true);
        text.IsTextSelectionEnabled = true;
        text.TextWrapping = TextWrapping.Wrap;
        text.MaxWidth = 300;
        var line = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        line.Children.Add(HealthGlyph(ok));
        line.Children.Add(text);
        return Row(label, line);
    }

    /// <summary>Two sections side by side when there is room, stacked when there isn't.</summary>
    public static Grid Columns(UIElement left, UIElement right, double breakpoint = 720)
    {
        var grid = new Grid { ColumnSpacing = 16, RowSpacing = 4 };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.Children.Add(left);
        grid.Children.Add(right);
        if (left is FrameworkElement l) l.VerticalAlignment = VerticalAlignment.Top;
        if (right is FrameworkElement r) r.VerticalAlignment = VerticalAlignment.Top;

        void Arrange()
        {
            var wide = grid.ActualWidth >= breakpoint;
            grid.ColumnDefinitions[1].Width = wide ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
            Grid.SetColumn((FrameworkElement)right, wide ? 1 : 0);
            Grid.SetRow((FrameworkElement)right, wide ? 0 : 1);
        }
        grid.SizeChanged += (_, _) => Arrange();
        Arrange();
        return grid;
    }

    /// <param name="first">The first thing under a page heading, which already leaves space: no extra space above it.</param>
    public static StackPanel Section(string header, UIElement body, bool first = false)
    {
        var stack = new StackPanel { Spacing = 12 };
        var title = Text(header, "BodyStrongTextBlockStyle");
        title.Margin = new Thickness(2, first ? 0 : 24, 0, 0);
        stack.Children.Add(title);
        stack.Children.Add(body);
        return stack;
    }

    private const double PageMaxWidth = 1100;
    private const double PageGutter = 48;

    /// <summary>A content column no wider than <see cref="PageMaxWidth"/>, centred in the space it is
    /// given. Sized explicitly: MaxWidth on a stretched element did not centre reliably.</summary>
    public static FrameworkElement Column(UIElement content)
    {
        var inner = new Grid { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 0, 0, 48) };
        inner.Children.Add(content);
        var outer = new Grid { HorizontalAlignment = HorizontalAlignment.Stretch };
        outer.Children.Add(inner);
        outer.SizeChanged += (_, e) => inner.Width = Math.Max(0, Math.Min(PageMaxWidth, e.NewSize.Width - 2 * PageGutter));
        return outer;
    }

    /// <summary>A scrolling page whose content is a centred column.</summary>
    public static ScrollViewer Page(UIElement content) => new()
    {
        Content = Column(content),
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
    };

    /// <summary>Every page's heading sits in a bar of this height, so what is below it never moves, whether the
    /// heading is a plain title or a "Hardware > System" breadcrumb.</summary>
    public const double HeaderHeight = 80;

    public static FrameworkElement HeaderBar(UIElement content)
    {
        var bar = new Grid { Height = HeaderHeight, Margin = new Thickness(2, 0, 0, 0) };
        if (content is FrameworkElement element) element.VerticalAlignment = VerticalAlignment.Center;
        bar.Children.Add(content);
        return bar;
    }

    public static FrameworkElement Header(string title) => HeaderBar(Text(title, "TitleTextBlockStyle"));
}

/// <summary>Dialogs shown over the window. WinUI allows one at a time, so they queue.</summary>
internal static class Dialogs
{
    private static readonly SemaphoreSlim Gate = new(1, 1);

    public static XamlRoot? Root { get; set; }

    public static async Task ShowAsync(ContentDialog dialog)
    {
        if (Root == null) return;
        await Gate.WaitAsync();
        try
        {
            dialog.XamlRoot = Root;
            // Dialogs are hosted at the window root and do not inherit its theme.
            if (Root.Content is FrameworkElement window) dialog.RequestedTheme = window.ActualTheme;
            await dialog.ShowAsync();
        }
        finally { Gate.Release(); }
    }

    public static Task ErrorAsync(string title, string? message) => ShowAsync(new ContentDialog
    {
        Title = title,
        Content = Ui.Text(message ?? Loc.T("common.unknownError"), wrap: true),
        CloseButtonText = Loc.T("common.ok"),
        DefaultButton = ContentDialogButton.Close,
    });
}
