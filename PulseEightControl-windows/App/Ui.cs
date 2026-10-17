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

    /// <summary>Label on the left, value or control on the right.</summary>
    public static Grid Row(string label, UIElement value, string? caption = null)
    {
        var grid = new Grid { Padding = new Thickness(16, 12, 16, 12), ColumnSpacing = 16, MinHeight = 48 };
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

    public static StackPanel Section(string header, UIElement body)
    {
        var stack = new StackPanel { Spacing = 8 };
        var title = Text(header, "BodyStrongTextBlockStyle");
        title.Margin = new Thickness(2, 12, 0, 0);
        stack.Children.Add(title);
        stack.Children.Add(body);
        return stack;
    }

    private const double PageMaxWidth = 1100;
    private const double PageGutter = 36;

    /// <summary>A content column no wider than <see cref="PageMaxWidth"/>, centred in the space it is
    /// given. Sized explicitly: MaxWidth on a stretched element did not centre reliably.</summary>
    public static FrameworkElement Column(UIElement content)
    {
        var inner = new Grid { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 8, 0, 24) };
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

    public static FrameworkElement Header(string title)
    {
        var text = Text(title, "TitleTextBlockStyle");
        text.Margin = new Thickness(2, 16, 0, 4);
        return text;
    }
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
