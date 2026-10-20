using System.Numerics;
using System.Text.Json;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Hosting;
using PulseEight.Core;
using Windows.UI.ViewManagement;

namespace PulseEightControl.Views;

/// <summary>The Hardware section, laid out like Windows Settings: a list of topics (System, Features, Health...),
/// each opening its own page with a back button and a "Hardware > Topic" heading.</summary>
internal sealed class HardwareView : UserControl
{
    private static readonly string[] Backlight = ["off", "low", "high"];

    private enum Topic { System, Features, Health, Diagnostics, FrontPanel, Maintenance, Updates, Inputs, Outputs }

    private readonly CoreClient _core;
    private readonly Action<PortSnapshot> _openPort;
    private readonly Action _requestRestart;
    private readonly ScrollViewer _host = new() { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    private string _signature = "";
    private bool _building;
    private Topic? _topic; // null: the list of topics
    private Snapshot? _snapshot;
    private int _slide; // direction of the page change being drawn: 1 forward, -1 back, 0 none
    private FrameworkElement? _body; // what slides: the page below its heading
    private static readonly UISettings SystemSettings = new();

    /// <summary>Raised when <see cref="CanGoBack"/> may have changed, so the window can enable its back button.</summary>
    public event Action? BackStateChanged;

    public HardwareView(CoreClient core, Action<PortSnapshot> openPort, Action requestRestart)
    {
        _core = core;
        _openPort = openPort;
        _requestRestart = requestRestart;
        Content = _host;
    }

    public bool CanGoBack => _topic != null;

    public void Invalidate() => _signature = "";

    /// <summary>Back to the list of topics. False if already there.</summary>
    public bool GoBack()
    {
        if (_topic == null) return false;
        Open(null);
        return true;
    }

    private void Open(Topic? topic)
    {
        _slide = topic == null ? -1 : 1;
        _topic = topic;
        _signature = "";
        if (_snapshot != null) Apply(_snapshot, resetScroll: true);
        BackStateChanged?.Invoke();
    }

    public void Apply(Snapshot snapshot) => Apply(snapshot, resetScroll: false);

    private void Apply(Snapshot snapshot, bool resetScroll)
    {
        _snapshot = snapshot;
        var signature = JsonSerializer.Serialize(new
        {
            Topic = _topic,
            snapshot.AdminConfigured, snapshot.SystemRows, snapshot.SystemError, snapshot.HealthRows, snapshot.FeatureRows, snapshot.FrontPanel,
            snapshot.Updates, snapshot.Model, snapshot.Firmware,
            Inputs = snapshot.Inputs.Select(p => new { p.Name, p.Status, p.Type, p.UpdateAvailable }),
            Outputs = snapshot.Outputs.Select(p => new { p.Name, p.Status, p.Type, p.UpdateAvailable }),
        });
        if (signature == _signature) return;
        _signature = signature;

        var offset = resetScroll ? 0 : _host.VerticalOffset;
        _building = true;
        try { _host.Content = Build(snapshot); }
        finally { _building = false; }
        _host.UpdateLayout();
        _host.ChangeView(null, offset, null, disableAnimation: true);

        var slide = _slide;
        _slide = 0;
        if (slide != 0 && _body != null) SlideIn(_body, slide);
    }

    /// <summary>The page change of Windows Settings, for the content only (the heading stays put): the new content
    /// fades in while gliding a short way from the right (opening a topic) or from the left (going back). Runs on
    /// the compositor, off the UI thread, so it stays smooth while the page is being laid out. Skipped when the
    /// system has animations turned off.</summary>
    private static void SlideIn(FrameworkElement body, int direction)
    {
        if (!SystemSettings.AnimationsEnabled) return;

        var visual = ElementCompositionPreview.GetElementVisual(body);
        var compositor = visual.Compositor;
        ElementCompositionPreview.SetIsTranslationEnabled(body, true);

        // Fluent's "decelerate": fast off the mark, a long soft landing.
        var decelerate = compositor.CreateCubicBezierEasingFunction(new Vector2(0.1f, 0.9f), new Vector2(0.2f, 1f));
        var glide = compositor.CreateVector3KeyFrameAnimation();
        glide.InsertKeyFrame(0, new Vector3(48 * direction, 0, 0));
        glide.InsertKeyFrame(1, Vector3.Zero, decelerate);
        glide.Duration = TimeSpan.FromMilliseconds(450);

        var fade = compositor.CreateScalarKeyFrameAnimation();
        fade.InsertKeyFrame(0, 0);
        fade.InsertKeyFrame(1, 1, compositor.CreateLinearEasingFunction());
        fade.Duration = TimeSpan.FromMilliseconds(220);

        visual.Opacity = 0;
        visual.StartAnimation("Translation", glide);
        visual.StartAnimation("Opacity", fade);
    }

    // MARK: Pages

    private UIElement Build(Snapshot snapshot)
    {
        // A topic that has gone (e.g. the front panel once the admin password is removed) falls back to the list.
        if (_topic is { } topic && !Available(snapshot, topic))
        {
            _topic = null;
            BackStateChanged?.Invoke();
        }

        var page = new StackPanel { Spacing = 8 };
        if (_topic is not { } open)
        {
            page.Children.Add(Ui.Header(Loc.T("hardware.title")));
            page.Children.Add(_body = (FrameworkElement)Topics(snapshot));
        }
        else
        {
            page.Children.Add(Ui.HeaderBar(Breadcrumb(Title(open))));
            page.Children.Add(_body = (FrameworkElement)Body(snapshot, open));
        }
        return Ui.Column(page); // _host is the one ScrollViewer
    }

    private static bool Available(Snapshot snapshot, Topic topic) => topic switch
    {
        Topic.Health => snapshot.HealthRows.Any(r => r.Group != "diagnostics"),
        Topic.Diagnostics => snapshot.HealthRows.Any(r => r.Group == "diagnostics"),
        Topic.FrontPanel => snapshot.AdminConfigured && snapshot.FrontPanel != null,
        Topic.Maintenance => snapshot.AdminConfigured,
        _ => true,
    };

    private static string Title(Topic topic) => Loc.T(topic switch
    {
        Topic.System => "hardware.system",
        Topic.Features => "hardware.features",
        Topic.Health => "hardware.health",
        Topic.Diagnostics => "hardware.diagnostics",
        Topic.FrontPanel => "hardware.frontPanel",
        Topic.Maintenance => "hardware.maintenance",
        Topic.Updates => "hardware.firmwareUpdates",
        Topic.Inputs => "hardware.inputs",
        _ => "hardware.outputs",
    });

    private UIElement Body(Snapshot snapshot, Topic topic) => topic switch
    {
        Topic.System => SystemCard(snapshot),
        Topic.Features => Card(snapshot.FeatureRows),
        Topic.Health => HealthCard(snapshot.HealthRows.Where(r => r.Group != "diagnostics")),
        Topic.Diagnostics => HealthCard(snapshot.HealthRows.Where(r => r.Group == "diagnostics")),
        Topic.FrontPanel => FrontPanel(snapshot.FrontPanel!),
        Topic.Maintenance => Maintenance(),
        Topic.Updates => Updates(snapshot),
        Topic.Inputs => Ports(snapshot.Inputs),
        _ => Ports(snapshot.Outputs),
    };

    /// <summary>"Hardware > Topic" at the size of a page title, in the same bar as the plain title, so nothing below moves.
    /// Back is in the window's title bar, as in Windows Settings.</summary>
    private UIElement Breadcrumb(string title)
    {
        var parentText = Ui.Text(Loc.T("hardware.title"), "TitleTextBlockStyle");
        parentText.Opacity = 0.7;
        // A button sized to its text (no minimum height or width of its own), so every part of the line sits on the
        // same baseline as the plain title; the negative margin cancels its padding so "Hardware" starts where the
        // plain title does.
        var parent = new Button
        {
            Content = parentText, Background = Palette.Transparent, BorderThickness = new Thickness(0),
            MinHeight = 0, MinWidth = 0, Padding = new Thickness(8, 0, 8, 0), Margin = new Thickness(-8, 0, 0, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        parent.Click += (_, _) => GoBack();
        var separator = new FontIcon
        {
            Glyph = "", FontSize = 14, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center,
            Margin = new Thickness(0, 6, 8, 0), // centred on the lowercase letters, not on the line box (which sits higher)
        };
        var current = Ui.Text(title, "TitleTextBlockStyle");
        current.VerticalAlignment = VerticalAlignment.Center;

        var line = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        line.Children.Add(parent);
        line.Children.Add(separator);
        line.Children.Add(current);
        return line;
    }

    /// <summary>The list of topics: one card per topic, with an icon, a line of description and a chevron.</summary>
    private UIElement Topics(Snapshot snapshot)
    {
        var list = new StackPanel { Spacing = 6 };

        void Add(Topic topic, string glyph, string title, string description, FrameworkElement? trailing = null) =>
            list.Children.Add(Ui.Card(TopicRow(glyph, title, description, trailing, () => Open(topic))));

        static TextBlock Note(string text) => Ui.Text(text, "CaptionTextBlockStyle", secondary: true);

        Add(Topic.System, "", Loc.T("hardware.system"), Loc.T("hardware.system.description"),
            snapshot.Model is { Length: > 0 } model ? Note(model) : null);
        Add(Topic.Features, "", Loc.T("hardware.features"), Loc.T("hardware.features.description"));

        if (Available(snapshot, Topic.Health))
        {
            // One glance: a tick if the matrix says it is well and nothing it reports is not.
            var judged = snapshot.HealthRows.Where(r => r.Ok != null).ToList();
            Add(Topic.Health, "", Loc.T("hardware.health"), Loc.T("hardware.health.description"),
                judged.Count > 0 ? Ui.HealthGlyph(judged.All(r => r.Ok == true)) : null);
        }
        if (Available(snapshot, Topic.Diagnostics))
            Add(Topic.Diagnostics, "", Loc.T("hardware.diagnostics"), Loc.T("hardware.diagnostics.description"));
        if (Available(snapshot, Topic.FrontPanel))
            Add(Topic.FrontPanel, "", Loc.T("hardware.frontPanel"), Loc.T("hardware.frontPanel.description"));

        if (Available(snapshot, Topic.Maintenance))
            Add(Topic.Maintenance, "\uE7E8", Loc.T("hardware.maintenance"), Loc.T("hardware.maintenance.description"));

        Add(Topic.Updates, "", Loc.T("hardware.firmwareUpdates"), Loc.T("hardware.firmwareUpdates.description"),
            snapshot.Updates.Count > 0 ? Note(Loc.Count(snapshot.Updates.Count, "statusbar.firmwareUpdate.one", "statusbar.firmwareUpdate.other")) : null);
        Add(Topic.Inputs, "", Loc.T("hardware.inputs"), Loc.T("hardware.inputs.description"), Note(snapshot.Inputs.Count.ToString()));
        Add(Topic.Outputs, "", Loc.T("hardware.outputs"), Loc.T("hardware.outputs.description"), Note(snapshot.Outputs.Count.ToString()));
        return list;
    }

    private static UIElement TopicRow(string glyph, string title, string description, FrameworkElement? trailing, Action open)
    {
        var line = new Grid { ColumnSpacing = 16 };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var icon = new FontIcon { Glyph = glyph, FontSize = 20, Width = 24, VerticalAlignment = VerticalAlignment.Center };
        var text = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        text.Children.Add(Ui.Text(title));
        text.Children.Add(Ui.Text(description, "CaptionTextBlockStyle", secondary: true));
        Grid.SetColumn(text, 1);
        var chevron = new FontIcon { Glyph = "", FontSize = 12, Opacity = 0.6, VerticalAlignment = VerticalAlignment.Center };
        Grid.SetColumn(chevron, 3);

        line.Children.Add(icon);
        line.Children.Add(text);
        if (trailing != null)
        {
            trailing.VerticalAlignment = VerticalAlignment.Center;
            Grid.SetColumn(trailing, 2);
            line.Children.Add(trailing);
        }
        line.Children.Add(chevron);

        var button = new Button
        {
            Content = line, HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Background = Palette.Transparent, BorderThickness = new Thickness(0), CornerRadius = new CornerRadius(8),
            Padding = Ui.RowPadding, MinHeight = Ui.RowMinHeight,
        };
        button.Click += (_, _) => open();
        return button;
    }

    // MARK: Cards

    /// <summary>The system details, or why there are none: the matrix refused them, or they haven't arrived yet.</summary>
    private static UIElement SystemCard(Snapshot snapshot)
    {
        if (snapshot.SystemRows.Count > 0) return Card(snapshot.SystemRows);
        return snapshot.SystemError is { Length: > 0 } error
            ? Ui.Card(Ui.Row(Loc.T("hardware.systemError"), error))
            : Ui.Card(Ui.Row(Loc.T("hardware.systemPending"), ""));
    }

    private static UIElement Card(IReadOnlyList<LabeledValue> rows) =>
        rows.Count == 0
            ? Ui.Card(Ui.Row(Loc.T("hardware.nothingYet"), ""))
            : Ui.Card(rows.Select(r => (UIElement)Ui.Row(r.Label, r.Value)).ToArray());

    /// <summary>Rows of the matrix's report, with a tick or warning beside those it judges.</summary>
    private static UIElement HealthCard(IEnumerable<LabeledValue> source)
    {
        var rows = source.ToList();
        if (rows.Count == 0) return Ui.Card(Ui.Row(Loc.T("hardware.nothingYet"), ""));
        return Ui.Card(rows.Select(r => (UIElement)(r.Ok is { } ok ? Ui.HealthRow(r.Label, r.Value, ok) : Ui.Row(r.Label, r.Value))).ToArray());
    }

    private UIElement FrontPanel(FrontPanelSnapshot panel)
    {
        var rows = new List<UIElement>();

        if (panel.Backlight != null)
        {
            var picker = new ComboBox { MinWidth = 120 };
            Ui.LetPageScroll(picker, _host);
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

    /// <summary>Admin only. The button only asks; the window sends the restart after the person has confirmed.</summary>
    private UIElement Maintenance()
    {
        var restart = new Button { Content = Loc.T("maintenance.restartButton") };
        restart.Click += (_, _) => _requestRestart();
        return Ui.Card(Ui.Row(Loc.T("maintenance.restart"), restart, Loc.T("maintenance.restartCaption")));
    }

    private static UIElement Updates(Snapshot snapshot)
    {
        if (snapshot.Updates.Count == 0) return Ui.Card(Ui.Row(Loc.T("hardware.allUpToDate"), ""));
        return Ui.Card(snapshot.Updates
            .Select(u => (UIElement)Ui.Row(u.Name, u.FirmwareVersion is { Length: > 0 } v ? Loc.F("hardware.versionAvailable", v) : Loc.T("hardware.updateAvailable")))
            .ToArray());
    }

    private UIElement Ports(IReadOnlyList<PortSnapshot> ports)
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
                Padding = Ui.RowPadding, MinHeight = Ui.RowMinHeight,
            };
            button.Click += (_, _) => _openPort(port);
            return (UIElement)button;
        }).ToArray();

        return Ui.Card(rows);
    }
}
