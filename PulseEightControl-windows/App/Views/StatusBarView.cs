using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>Connection and device information along the bottom of the window, with separators.</summary>
internal sealed class StatusBarView : UserControl
{
    private readonly StackPanel _items = new() { Orientation = Orientation.Horizontal };
    private readonly Border _frame = new()
    {
        BorderThickness = new Thickness(0, 1, 0, 0), Padding = new Thickness(16, 6, 16, 6), MinHeight = 30,
    };
    private Snapshot? _snapshot;

    public StatusBarView()
    {
        _frame.Child = _items;
        Content = _frame;
    }

    public void Apply(Snapshot snapshot)
    {
        _snapshot = snapshot;
        _frame.BorderBrush = Palette.CardBorder;
        Visibility = snapshot.Settings.ShowStatusBar ? Visibility.Visible : Visibility.Collapsed;
        _items.Children.Clear();

        var connection = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var colour = snapshot.Phase switch
        {
            "connected" => Palette.Status(0),
            "connecting" => Palette.Status(2),
            "disconnected" => Palette.Status(1),
            _ => Palette.Status(3),
        };
        connection.Children.Add(Ui.Dot(colour));
        connection.Children.Add(Ui.Text(snapshot.Summary, "CaptionTextBlockStyle"));
        _items.Children.Add(connection);

        if (snapshot.IsConnected)
        {
            if (!string.IsNullOrEmpty(snapshot.Model))
                AddItem(snapshot.Firmware is { Length: > 0 } ? $"{snapshot.Model} · {snapshot.Firmware}" : snapshot.Model);
            AddItem(snapshot.AdminConfigured ? "Admin enabled" : "Read-only");
            if (snapshot.Updates.Count > 0)
                AddItem(snapshot.Updates.Count == 1 ? "1 firmware update" : $"{snapshot.Updates.Count} firmware updates");
        }
    }

    public void Restyle()
    {
        if (_snapshot != null) Apply(_snapshot);
    }

    private void AddItem(string text)
    {
        _items.Children.Add(Ui.VerticalSeparator());
        _items.Children.Add(Ui.Text(text, "CaptionTextBlockStyle"));
    }
}
