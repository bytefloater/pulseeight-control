using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>System details, features, the front panel, firmware updates and every port.</summary>
internal sealed class HardwareView : UserControl
{
    private static readonly string[] Backlight = ["off", "low", "high"];

    private readonly CoreClient _core;
    private readonly Action<PortSnapshot> _openPort;
    private readonly ScrollViewer _host = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private string _signature = "";
    private bool _building;

    public HardwareView(CoreClient core, Action<PortSnapshot> openPort)
    {
        _core = core;
        _openPort = openPort;
        Content = _host;
    }

    public void Invalidate() => _signature = "";

    public void Apply(Snapshot snapshot)
    {
        var signature = JsonSerializer.Serialize(new
        {
            snapshot.AdminConfigured, snapshot.SystemRows, snapshot.FeatureRows, snapshot.FrontPanel,
            snapshot.Updates, snapshot.Model, snapshot.Firmware,
            Inputs = snapshot.Inputs.Select(p => new { p.Name, p.Status, p.Type, p.UpdateAvailable }),
            Outputs = snapshot.Outputs.Select(p => new { p.Name, p.Status, p.Type, p.UpdateAvailable }),
        });
        if (signature == _signature) return;
        _signature = signature;

        var offset = _host.VerticalOffset;
        _building = true;
        try { _host.Content = Build(snapshot); }
        finally { _building = false; }
        _host.UpdateLayout();
        _host.ChangeView(null, offset, null, disableAnimation: true);
    }

    private UIElement Build(Snapshot snapshot)
    {
        var page = new StackPanel { Spacing = 4 };
        page.Children.Add(Ui.Header(Loc.T("hardware.title")));

        page.Children.Add(Ui.Columns(
            Ui.Section(Loc.T("hardware.system"), Card(snapshot.SystemRows)),
            Ui.Section(Loc.T("hardware.features"), Card(snapshot.FeatureRows))));

        var panel = snapshot.AdminConfigured ? snapshot.FrontPanel : null;
        var updates = Ui.Section(Loc.T("hardware.firmwareUpdates"), Updates(snapshot));
        page.Children.Add(panel is null ? updates : Ui.Columns(Ui.Section(Loc.T("hardware.frontPanel"), FrontPanel(panel)), updates));

        page.Children.Add(Ui.Columns(
            Ui.Section(Loc.T("hardware.inputs"), Ports(snapshot, snapshot.Inputs)),
            Ui.Section(Loc.T("hardware.outputs"), Ports(snapshot, snapshot.Outputs))));

        return Ui.Column(page); // _host is the one ScrollViewer
    }

    private static UIElement Card(IReadOnlyList<LabeledValue> rows) =>
        rows.Count == 0
            ? Ui.Card(Ui.Row(Loc.T("hardware.nothingYet"), ""))
            : Ui.Card(rows.Select(r => (UIElement)Ui.Row(r.Label, r.Value)).ToArray());

    private UIElement FrontPanel(FrontPanelSnapshot panel)
    {
        var rows = new List<UIElement>();

        if (panel.Backlight != null)
        {
            var picker = new ComboBox { MinWidth = 120 };
            foreach (var key in new[] { "hardware.backlight.off", "hardware.backlight.low", "hardware.backlight.high" }) picker.Items.Add(Loc.T(key));
            picker.SelectedIndex = Array.IndexOf(Backlight, panel.Backlight);
            picker.SelectionChanged += async (_, _) =>
            {
                if (_building || picker.SelectedIndex < 0) return;
                var level = Backlight[picker.SelectedIndex];
                if (level == panel.Backlight) return;
                picker.IsEnabled = false;
                var result = await _core.SetBacklightAsync(level);
                picker.IsEnabled = true;
                if (!result.Ok)
                {
                    picker.SelectedIndex = Array.IndexOf(Backlight, panel.Backlight);
                    await Dialogs.ErrorAsync(Loc.T("hardware.backlightError"), result.Error);
                }
            };
            rows.Add(Ui.Row(Loc.T("hardware.backlight"), picker));
        }

        if (panel.StatusLed is { } led)
        {
            var toggle = new ToggleSwitch { IsOn = led, OnContent = "", OffContent = "", MinWidth = 0 };
            toggle.Toggled += async (_, _) =>
            {
                if (_building || toggle.IsOn == led) return;
                toggle.IsEnabled = false;
                var result = await _core.SetStatusLedAsync(toggle.IsOn);
                toggle.IsEnabled = true;
                if (!result.Ok)
                {
                    toggle.IsOn = led;
                    await Dialogs.ErrorAsync(Loc.T("hardware.statusLightError"), result.Error);
                }
            };
            rows.Add(Ui.Row(Loc.T("hardware.statusLight"), toggle));
        }

        return Ui.Card(rows.ToArray());
    }

    private static UIElement Updates(Snapshot snapshot)
    {
        if (snapshot.Updates.Count == 0) return Ui.Card(Ui.Row(Loc.T("hardware.allUpToDate"), ""));
        return Ui.Card(snapshot.Updates
            .Select(u => (UIElement)Ui.Row(u.Name, u.FirmwareVersion is { Length: > 0 } v ? Loc.F("hardware.versionAvailable", v) : Loc.T("hardware.updateAvailable")))
            .ToArray());
    }

    private UIElement Ports(Snapshot snapshot, IReadOnlyList<PortSnapshot> ports)
    {
        if (ports.Count == 0) return Ui.Card(Ui.Row(Loc.T("hardware.noPorts"), ""));

        var rows = ports.Select(port =>
        {
            var line = new Grid { ColumnSpacing = 10 };
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            line.Children.Add(Ui.Dot(Palette.Status(port.Status)));
            var name = Ui.Text($"{port.Number}  {port.Name}");
            name.TextTrimming = TextTrimming.CharacterEllipsis;
            Grid.SetColumn(name, 1);
            line.Children.Add(name);

            var detail = Ui.Text(
                port.UpdateAvailable ? Loc.F("hardware.portUpdateAvailable", port.StatusLabel) : port.StatusLabel,
                "CaptionTextBlockStyle", secondary: true);
            detail.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(detail, 2);
            line.Children.Add(detail);

            var chevron = new FontIcon { Glyph = "", FontSize = 12, Opacity = 0.6 };
            Grid.SetColumn(chevron, 3);
            line.Children.Add(chevron);

            var button = new Button
            {
                Content = line, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
                Background = Palette.Transparent, BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(0),
                Padding = new Thickness(16, 12, 16, 12), MinHeight = 48,
            };
            button.Click += (_, _) => _openPort(port);
            return (UIElement)button;
        }).ToArray();

        return Ui.Card(rows);
    }
}
