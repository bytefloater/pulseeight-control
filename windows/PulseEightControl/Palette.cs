using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI;
using Windows.UI.ViewManagement;

namespace PulseEightControl;

/// <summary>
/// Colours for the parts that are drawn by hand (the routing grid, cards, the status bar).
/// Standard controls theme themselves; these follow the window's actual light/dark theme, which
/// <see cref="Update"/> refreshes whenever it changes.
/// </summary>
internal static class Palette
{
    public static bool Dark { get; private set; }

    public static SolidColorBrush Accent { get; } = new();
    public static Brush OnAccent { get; } = new SolidColorBrush(Colors.White);
    public static SolidColorBrush Pending { get; } = new();
    public static SolidColorBrush Cell { get; } = new();
    public static SolidColorBrush CellLine { get; } = new();
    public static SolidColorBrush CellBorder { get; } = new();
    public static SolidColorBrush HeaderHover { get; } = new();
    public static SolidColorBrush Card { get; } = new();
    public static SolidColorBrush CardBorder { get; } = new();
    public static SolidColorBrush Separator { get; } = new();
    public static Brush Transparent { get; } = new SolidColorBrush(Colors.Transparent);

    private static Brush Solid(byte a, byte r, byte g, byte b) => new SolidColorBrush(Color.FromArgb(a, r, g, b));
    private static Color Rgba(byte a, byte r, byte g, byte b) => Color.FromArgb(a, r, g, b);

    public static void Update(ElementTheme theme)
    {
        Dark = theme == ElementTheme.Dark;
        Accent.Color = new UISettings().GetColorValue(UIColorType.Accent);
        Pending.Color = Rgba(255, 0xF7, 0x63, 0x0C);
        if (Dark)
        {
            Cell.Color = Rgba(0x0F, 255, 255, 255);
            CellLine.Color = Rgba(0x26, 255, 255, 255);
            CellBorder.Color = Rgba(0x19, 255, 255, 255);
            HeaderHover.Color = Rgba(0x1A, 255, 255, 255);
            Card.Color = Rgba(0x0D, 255, 255, 255);
            CardBorder.Color = Rgba(0x19, 255, 255, 255);
            Separator.Color = Rgba(0x1F, 255, 255, 255);
        }
        else
        {
            Cell.Color = Rgba(0xB3, 255, 255, 255);
            CellLine.Color = Rgba(0x14, 0, 0, 0);
            CellBorder.Color = Rgba(0x1A, 0, 0, 0);
            HeaderHover.Color = Rgba(0x0F, 0, 0, 0);
            Card.Color = Rgba(0xB3, 255, 255, 255);
            CardBorder.Color = Rgba(0x14, 0, 0, 0);
            Separator.Color = Rgba(0x1F, 0, 0, 0);
        }
    }

    /// <summary>Colour for a port status code (0 ok, 1 module fault, 2 warning, 3 no signal, 4 not present).</summary>
    public static Brush Status(int status) => status switch
    {
        0 => Dark ? Solid(255, 0x6C, 0xCB, 0x5F) : Solid(255, 0x0F, 0x7B, 0x0F),
        1 => Dark ? Solid(255, 0xFF, 0x99, 0xA4) : Solid(255, 0xC4, 0x2B, 0x1C),
        2 => Dark ? Solid(255, 0xFC, 0xE1, 0x00) : Solid(255, 0x9D, 0x5D, 0x00),
        _ => Solid(255, 0x8A, 0x8A, 0x8A),
    };
}
