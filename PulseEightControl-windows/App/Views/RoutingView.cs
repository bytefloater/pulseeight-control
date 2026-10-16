using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Shapes;
using PulseEight.Core;
using Windows.Foundation;

namespace PulseEightControl.Views;

/// <summary>
/// The routing matrix: inputs along the top (names written upwards), outputs down the left, and a
/// cell where they cross. Clicking a cell routes that input to that output; clicking a header opens
/// the port. Hovering lights the row and column.
/// </summary>
internal sealed class RoutingView : UserControl
{
    private const double Pitch = 28;
    private const double Gap = 4;
    private const double RowHeaderWidth = 156;

    private readonly CoreClient _core;
    private readonly Action<PortSnapshot> _openPort;
    private readonly ScrollViewer _scroll = new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        HorizontalScrollMode = ScrollMode.Auto,
        VerticalScrollMode = ScrollMode.Auto,
    };

    private readonly Dictionary<int, int> _pending = new(); // output bay -> input bay being routed
    private Snapshot? _snapshot;
    private string _signature = "";

    private Border[,] _cells = new Border[0, 0];
    private Border[] _columnHeaders = [];
    private Border[] _rowHeaders = [];
    private int _hoverInput = -1;
    private int _hoverOutput = -1;

    public RoutingView(CoreClient core, Action<PortSnapshot> openPort)
    {
        _core = core;
        _openPort = openPort;
        Content = _scroll;
    }

    /// <summary>Forces a redraw on the next <see cref="Apply"/> (after a theme change).</summary>
    public void Invalidate() => _signature = "";

    public void Apply(Snapshot snapshot)
    {
        _snapshot = snapshot;
        foreach (var output in snapshot.Outputs)
            if (_pending.TryGetValue(output.Bay, out var wanted) && output.ReceiveFrom == wanted)
                _pending.Remove(output.Bay);

        var signature = string.Join(';', snapshot.Inputs.Select(p => $"{p.Name}|{p.Status}"))
            + "#" + string.Join(';', snapshot.Outputs.Select(p => $"{p.Name}|{p.Status}|{p.ReceiveFrom}"))
            + "#" + string.Join(',', _pending.Select(p => $"{p.Key}>{p.Value}"));
        if (signature == _signature) return;
        _signature = signature;
        Rebuild(snapshot);
    }

    private void Rebuild(Snapshot snapshot)
    {
        var horizontal = _scroll.HorizontalOffset;
        var vertical = _scroll.VerticalOffset;
        var inputs = snapshot.Inputs;
        var outputs = snapshot.Outputs;
        _hoverInput = _hoverOutput = -1;

        var longest = inputs.Count == 0 ? 0 : inputs.Max(i => i.Name.Length);
        var textLength = Math.Clamp(longest * 7.0, 60, 150);
        var headerHeight = textLength + 22;

        var grid = new Grid { RowSpacing = Gap, ColumnSpacing = Gap, Margin = new Thickness(20), HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(RowHeaderWidth) });
        foreach (var _ in inputs) grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(Pitch) });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(headerHeight) });
        foreach (var _ in outputs) grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(Pitch) });

        _columnHeaders = new Border[inputs.Count];
        _rowHeaders = new Border[outputs.Count];
        _cells = new Border[outputs.Count, inputs.Count];

        for (var column = 0; column < inputs.Count; column++)
        {
            var header = ColumnHeader(inputs[column], textLength);
            Grid.SetColumn(header, column + 1);
            grid.Children.Add(header);
            _columnHeaders[column] = header;
        }

        for (var row = 0; row < outputs.Count; row++)
        {
            var header = RowHeader(outputs[row]);
            Grid.SetRow(header, row + 1);
            grid.Children.Add(header);
            _rowHeaders[row] = header;

            for (var column = 0; column < inputs.Count; column++)
            {
                var cell = Cell(inputs[column], outputs[row], row, column);
                Grid.SetRow(cell, row + 1);
                Grid.SetColumn(cell, column + 1);
                grid.Children.Add(cell);
                _cells[row, column] = cell;
            }
        }

        _scroll.Content = grid;
        _scroll.UpdateLayout();
        _scroll.ChangeView(horizontal, vertical, null, disableAnimation: true);
    }

    // MARK: Headers

    private Border ColumnHeader(PortSnapshot input, double textLength)
    {
        // Rotation does not change layout size, so the text sits in a canvas of its rotated size.
        var canvas = new Canvas { Width = Pitch, Height = textLength };
        var label = new TextBlock
        {
            Text = input.Name, Width = textLength, Height = 20, TextAlignment = TextAlignment.Left,
            TextTrimming = TextTrimming.CharacterEllipsis, FontSize = 12,
            RenderTransformOrigin = new Point(0.5, 0.5),
            RenderTransform = new Microsoft.UI.Xaml.Media.RotateTransform { Angle = -90 },
        };
        Canvas.SetLeft(label, (Pitch - textLength) / 2);
        Canvas.SetTop(label, (textLength - 20) / 2);
        canvas.Children.Add(label);

        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Bottom, Spacing = 6 };
        stack.Children.Add(canvas);
        stack.Children.Add(Ui.Dot(Palette.Status(input.Status)));
        stack.Children.Add(new Border { Height = 2 });

        var border = new Border { Child = stack, Background = Palette.Transparent, CornerRadius = new CornerRadius(6) };
        Describe(border, input);
        border.Tapped += (_, _) => _openPort(input);
        border.PointerEntered += (_, _) => SetHover(-1, input.Bay);
        border.PointerExited += (_, _) => SetHover(-1, -1);
        return border;
    }

    private Border RowHeader(PortSnapshot output)
    {
        var panel = new Grid { ColumnSpacing = 8, Padding = new Thickness(8, 0, 8, 0) };
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        panel.Children.Add(Ui.Dot(Palette.Status(output.Status)));
        var name = new TextBlock { Text = output.Name, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
        Grid.SetColumn(name, 1);
        panel.Children.Add(name);

        var border = new Border { Child = panel, Background = Palette.Transparent, CornerRadius = new CornerRadius(6) };
        Describe(border, output);
        border.Tapped += (_, _) => _openPort(output);
        border.PointerEntered += (_, _) => SetHover(output.Bay, -1);
        border.PointerExited += (_, _) => SetHover(-1, -1);
        return border;
    }

    private static void Describe(UIElement element, PortSnapshot port)
    {
        var text = $"{port.Name} (port {port.Number}) · {port.StatusLabel}";
        ToolTipService.SetToolTip(element, text);
        AutomationProperties.SetName(element, text);
    }

    // MARK: Cells

    private Border Cell(PortSnapshot input, PortSnapshot output, int row, int column)
    {
        var routed = output.ReceiveFrom == input.Bay;
        var pending = _pending.TryGetValue(output.Bay, out var wanted) && wanted == input.Bay;

        var cell = new Border
        {
            Width = Pitch, Height = Pitch, CornerRadius = new CornerRadius(4), BorderThickness = new Thickness(1),
            Background = pending ? Palette.Pending : routed ? Palette.Accent : Palette.Cell,
            BorderBrush = Palette.CellBorder,
            Tag = routed || pending, // active cells keep their colour while hovered
        };
        if (pending)
        {
            // Waiting for the matrix to confirm: an indeterminate ring in place of the tick.
            cell.Child = new ProgressRing
            {
                IsActive = true, IsIndeterminate = true, Width = 14, Height = 14, Foreground = Palette.OnAccent,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            };
        }
        else if (routed)
        {
            cell.Child = new FontIcon
            {
                Glyph = "", FontSize = 14, Foreground = Palette.OnAccent, // CheckMark
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            };
        }

        var tip = $"{input.Name} → {output.Name}";
        ToolTipService.SetToolTip(cell, tip);
        AutomationProperties.SetName(cell, pending ? $"{tip}, routing" : routed ? $"{tip}, routed" : tip);
        cell.Tapped += (_, _) => Route(input, output);
        cell.PointerEntered += (_, _) => SetHover(row, column);
        cell.PointerExited += (_, _) => SetHover(-1, -1);
        return cell;
    }

    private void SetHover(int row, int column)
    {
        // Headers pass a row (outputs) or a column (inputs); cells pass both.
        var rowChanged = row != _hoverOutput;
        var columnChanged = column != _hoverInput;
        if (!rowChanged && !columnChanged) return;
        Paint(_hoverOutput, _hoverInput, on: false);
        _hoverOutput = row;
        _hoverInput = column;
        Paint(row, column, on: true);
    }

    private void Paint(int row, int column, bool on)
    {
        if (_snapshot is { Settings.HighlightGrid: false }) return;
        if (row >= 0 && row < _rowHeaders.Length)
        {
            _rowHeaders[row].Background = on ? Palette.HeaderHover : Palette.Transparent;
            for (var c = 0; c < _columnHeaders.Length; c++) Tint(_cells[row, c], on);
        }
        if (column >= 0 && column < _columnHeaders.Length)
        {
            _columnHeaders[column].Background = on ? Palette.HeaderHover : Palette.Transparent;
            for (var r = 0; r < _rowHeaders.Length; r++) Tint(_cells[r, column], on);
        }
    }

    private static void Tint(Border cell, bool on)
    {
        if (cell.Tag is true) return;
        cell.Background = on ? Palette.CellLine : Palette.Cell;
    }

    private async void Route(PortSnapshot input, PortSnapshot output)
    {
        if (_snapshot == null || output.ReceiveFrom == input.Bay || _pending.ContainsKey(output.Bay)) return;

        _pending[output.Bay] = input.Bay;
        _signature = "";
        Apply(_snapshot);

        var result = await _core.RouteAsync(input.Bay, output.Bay);
        if (!result.Ok)
        {
            _pending.Remove(output.Bay);
            _signature = "";
            if (_snapshot != null) Apply(_snapshot);
            await Dialogs.ErrorAsync($"Couldn't route {output.Name}", result.Error);
            return;
        }

        // The matrix confirms by changing the snapshot; if it never does, stop showing "pending".
        await Task.Delay(TimeSpan.FromSeconds(8));
        if (_pending.Remove(output.Bay) && _snapshot != null)
        {
            _signature = "";
            Apply(_snapshot);
        }
    }
}
