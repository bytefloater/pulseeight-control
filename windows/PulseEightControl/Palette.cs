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

    public static Brush Accent { get; private set; } = new SolidColorBrush();
    public static Brush OnAccent { get; } = new SolidColorBrush(Colors.White);
    public static Brush Pending { get; private set; } = new SolidColorBrush();
    public static Brush Cell { get; private set; } = new SolidColorBrush();
    public static Brush CellLine { get; private set; } = new SolidColorBrush();
    public static Brush CellBorder { get; private set; } = new SolidColorBrush();
    public static Brush HeaderHover { get; private set; } = new SolidColorBrush();
    public static Brush Card { get; private set; } = new SolidColorBrush();
    public static Brush CardBorder { get; private set; } = new SolidColorBrush();
    public static Brush Separator { get; private set; } = new SolidColorBrush();
    public static Brush Transparent { get; } = new SolidColorBrush(Colors.Transparent);

    private static Brush Solid(byte a, byte r, byte g, byte b) => new SolidColorBrush(Color.FromArgb(a, r, g, b));

    public static void Update(ElementTheme theme)
    {
        Dark = theme == ElementTheme.Dark;
        Accent = new SolidColorBrush(new UISettings().GetColorValue(UIColorType.Accent));
        Pending = Solid(255, 0xF7, 0x63, 0x0C);
        if (Dark)
        {
            Cell = Solid(0x0F, 255, 255, 255);
            CellLine = Solid(0x26, 255, 255, 255);
            CellBorder = Solid(0x19, 255, 255, 255);
            HeaderHover = Solid(0x1A, 255, 255, 255);
            Card = Solid(0x0D, 255, 255, 255);
            CardBorder = Solid(0x19, 255, 255, 255);
            Separator = Solid(0x1F, 255, 255, 255);
        }
        else
        {
            Cell = Solid(0xB3, 255, 255, 255);
            CellLine = Solid(0x14, 0, 0, 0);
            CellBorder = Solid(0x1A, 0, 0, 0);
            HeaderHover = Solid(0x0F, 0, 0, 0);
            Card = Solid(0xB3, 255, 255, 255);
            CardBorder = Solid(0x14, 0, 0, 0);
            Separator = Solid(0x1F, 0, 0, 0);
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
