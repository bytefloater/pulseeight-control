using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using PulseEight.Core;
using PulseEightControl.Updates;
using PulseEightControl.Views;
using Windows.Graphics;
using Windows.System;
using Windows.UI;

namespace PulseEightControl;

public sealed class MainWindow : Window
{
    private readonly CoreClient _core = new();
    private readonly UpdateController _updates;
    private readonly TitleBar _titleBar = new();
    private readonly NavigationView _navigation = new();
    private readonly Border _content = new();
    private readonly StatusBarView _statusBar = new();
    private readonly NavigationViewItem _routingItem;
    private readonly NavigationViewItem _hardwareItem;
    private readonly NavigationViewItem _aboutItem;
    private AboutView _about;
    private readonly RoutingView _routing;
    private readonly HardwareView _hardware;
    private SettingsView _settings;
    private ConnectionView _connection;
    private readonly Grid _root = new();
    private readonly DropDownButton _matrixPicker = new() { Margin = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Left };
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _graceTimer;
    private DateTime _graceEnds;
    private string _matrixSignature = "";

    /// <summary>How long a new connection attempt is given before the window says the matrix can't be reached.
    /// A first attempt can fail for a moment (the network is just up, the matrix is waking), and "Can't reach
    /// the matrix" for something that then fixes itself is a false alarm.</summary>
    private static readonly TimeSpan ConnectionGrace = TimeSpan.FromSeconds(5);

    private Snapshot _snapshot = null!;
    private bool _openedSettingsForSetup;
    private bool _navigationReady; // NavigationView's built-in Settings item exists only once it has loaded

    public MainWindow()
    {
        _snapshot = _core.Snapshot;
        Loc.Load(_core.GetStrings(), _snapshot.Language);
        Title = Loc.T("app.title");
        _titleBar.Title = Loc.T("app.title");
        // The logo in the title bar, and as the window's (taskbar and Alt-Tab) icon.
        if (AppAssets.Find("AppIcon.ico") is { } icon) AppWindow.SetIcon(icon);
        if (AppAssets.Find("Logo.png") is { } logo)
            _titleBar.IconSource = new ImageIconSource { ImageSource = new BitmapImage(new Uri(logo)) { DecodePixelWidth = 32 } };
        // Modern WinUI 3 title bar: the app draws it (so Mica runs right to the top edge) and the
        // system keeps the caption buttons.
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(_titleBar);
        // Back lives in the title bar, as in Windows Settings: always there, enabled when a page can go back.
        _titleBar.IsBackButtonVisible = true;
        _titleBar.IsBackButtonEnabled = false;
        _titleBar.BackRequested += (_, _) => _hardware.GoBack();
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new SizeInt32(1100, 780));

        _routing = new RoutingView(_core, port => _ = PortDialog.ShowAsync(_core, port, _snapshot));
        _hardware = new HardwareView(_core, port => _ = PortDialog.ShowAsync(_core, port, _snapshot));
        _hardware.BackStateChanged += UpdateBackButton;
        _updates = new UpdateController(DispatcherQueue, () => _snapshot.Settings.CheckForUpdates);
        _updates.Changed += () => _settings.ShowUpdateState();
        _graceTimer = DispatcherQueue.CreateTimer();
        _graceTimer.IsRepeating = false;
        _graceTimer.Tick += (_, _) => { _graceTimer.Stop(); Refresh(); };
        _settings = new SettingsView(_core, _updates, BeginConnectionGrace);
        _about = new AboutView(_updates.InstalledVersion);
        _connection = new ConnectionView(_core, SelectSettings, BeginConnectionGrace);
        _navigation.PaneHeader = _matrixPicker;
        _matrixPicker.Visibility = Visibility.Collapsed;

        _routingItem = new NavigationViewItem { Content = Loc.T("nav.routing"), Tag = "routing", Icon = new FontIcon { Glyph = "" } };
        _hardwareItem = new NavigationViewItem { Content = Loc.T("nav.hardware"), Tag = "hardware", Icon = new FontIcon { Glyph = "" } };

        _aboutItem = new NavigationViewItem { Content = Loc.T("nav.about"), Tag = "about", Icon = new FontIcon { Glyph = "\uE946" } };

        _navigation.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _navigation.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _navigation.IsPaneToggleButtonVisible = false;
        _navigation.IsPaneOpen = true;
        _navigation.OpenPaneLength = 200;
        _navigation.IsSettingsVisible = true;
        _navigation.MenuItems.Add(_routingItem);
        _navigation.MenuItems.Add(_hardwareItem);
        _navigation.FooterMenuItems.Add(_aboutItem); // above the built-in Settings item
        _navigation.Content = _content;
        _navigation.SelectionChanged += (_, _) => ShowSelectedPage();

        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.Children.Add(_titleBar);
        Grid.SetRow(_navigation, 1);
        _root.Children.Add(_navigation);
        Grid.SetRow(_statusBar, 2);
        _root.Children.Add(_statusBar);
        Content = _root;

        AddShortcut(VirtualKey.Number1, () => _navigation.SelectedItem = _routingItem);
        AddShortcut(VirtualKey.Number2, () => _navigation.SelectedItem = _hardwareItem);
        AddShortcut(VirtualKey.R, () =>
        {
            BeginConnectionGrace();
            _ = _core.RetryAsync();
        });
        AddShortcut(VirtualKey.Number3, SelectSettings);
        var goBack = new KeyboardAccelerator { Key = VirtualKey.Left, Modifiers = VirtualKeyModifiers.Menu };
        goBack.Invoked += (_, args) =>
        {
            if (!_hardware.CanGoBack || !ReferenceEquals(_content.Child, _hardware)) return;
            _hardware.GoBack();
            args.Handled = true;
        };
        _root.KeyboardAccelerators.Add(goBack);

        _root.Loaded += (_, _) =>
        {
            Dialogs.Root = _root.XamlRoot;
            Palette.Update(_root.ActualTheme);
            ApplyCaptionColors(_root.ActualTheme);
            _routing.Invalidate();
            _hardware.Invalidate();
            Refresh();
            _updates.StartAutomaticChecks(); // dialogs can be shown from here on
        };
        _navigation.Loaded += (_, _) =>
        {
            _navigationReady = true;
            ApplyNavigationText(); // the built-in Settings item exists only now
            Refresh();
        };
        _root.ActualThemeChanged += (_, _) =>
        {
            Palette.Update(_root.ActualTheme);
            ApplyCaptionColors(_root.ActualTheme);
            _routing.Invalidate();
            _hardware.Invalidate();
            Refresh();
        };

        Closed += (_, _) => Shutdown();

        Palette.Update(ElementTheme.Light);
        _navigation.SelectedItem = _routingItem;
        _graceEnds = DateTime.UtcNow + ConnectionGrace; // the app has just started connecting
        _graceTimer.Interval = ConnectionGrace;
        _graceTimer.Start();
        _core.Changed += snapshot => DispatcherQueue.TryEnqueue(() => OnChanged(snapshot));
        ApplyTheme(_snapshot);
        Refresh();
    }

    /// <summary>Loads the text for the language now in force and rebuilds what holds text from it.
    /// Pages that are rebuilt from every snapshot (routing, hardware, status bar) pick it up on their
    /// own; the settings and connection pages are built once, so they are replaced.</summary>
    private void ApplyLanguage(Snapshot snapshot)
    {
        Loc.Load(_core.GetStrings(), snapshot.Language);
        Title = Loc.T("app.title");
        _titleBar.Title = Loc.T("app.title");
        ApplyNavigationText();
        _settings = new SettingsView(_core, _updates, BeginConnectionGrace);
        _about = new AboutView(_updates.InstalledVersion);
        _connection = new ConnectionView(_core, SelectSettings, BeginConnectionGrace);
        _matrixSignature = ""; // the picker holds text too
        _routing.Invalidate();
        _hardware.Invalidate();
    }

    private void ApplyNavigationText()
    {
        _routingItem.Content = Loc.T("nav.routing");
        _hardwareItem.Content = Loc.T("nav.hardware");
        _aboutItem.Content = Loc.T("nav.about");
        if (_navigation.SettingsItem is NavigationViewItem settings) settings.Content = Loc.T("nav.settings");
    }

    /// <summary>The caption buttons follow the system theme unless told otherwise; make them follow
    /// the app's, which can differ (Settings > Appearance).</summary>
    private void ApplyCaptionColors(ElementTheme theme)
    {
        var titleBar = AppWindow.TitleBar;
        var dark = theme == ElementTheme.Dark;
        var foreground = dark ? Color.FromArgb(255, 255, 255, 255) : Color.FromArgb(255, 0, 0, 0);
        var hover = dark ? Color.FromArgb(24, 255, 255, 255) : Color.FromArgb(18, 0, 0, 0);
        var pressed = dark ? Color.FromArgb(16, 255, 255, 255) : Color.FromArgb(12, 0, 0, 0);
        var inactive = dark ? Color.FromArgb(255, 143, 143, 143) : Color.FromArgb(255, 153, 153, 153);
        var clear = Color.FromArgb(0, 0, 0, 0);

        titleBar.ButtonBackgroundColor = clear;
        titleBar.ButtonInactiveBackgroundColor = clear;
        titleBar.ButtonForegroundColor = foreground;
        titleBar.ButtonInactiveForegroundColor = inactive;
        titleBar.ButtonHoverBackgroundColor = hover;
        titleBar.ButtonHoverForegroundColor = foreground;
        titleBar.ButtonPressedBackgroundColor = pressed;
        titleBar.ButtonPressedForegroundColor = foreground;
    }

    private void AddShortcut(VirtualKey key, Action action)
    {
        var accelerator = new KeyboardAccelerator { Key = key, Modifiers = VirtualKeyModifiers.Control };
        accelerator.Invoked += (_, args) => { action(); args.Handled = true; };
        _root.KeyboardAccelerators.Add(accelerator);
    }

    private void OnChanged(Snapshot snapshot)
    {
        _snapshot = snapshot;
        if (snapshot.Language != Loc.Current) ApplyLanguage(snapshot);
        ApplyTheme(snapshot);
        Refresh();
    }

    private void ApplyTheme(Snapshot snapshot)
    {
        var wanted = snapshot.Settings.Appearance switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        if (_root.RequestedTheme != wanted) _root.RequestedTheme = wanted;
    }

    /// <summary>Starts the grace period for a new connection attempt (a retry, a saved or another matrix).</summary>
    private void BeginConnectionGrace()
    {
        _graceEnds = DateTime.UtcNow + ConnectionGrace;
        _graceTimer.Stop();
        _graceTimer.Interval = ConnectionGrace;
        _graceTimer.Start();
        Refresh();
    }

    /// <summary>What the window shows: a failure still inside its grace period counts as still connecting.</summary>
    private Snapshot Displayed(Snapshot snapshot) =>
        snapshot.Phase == "disconnected" && DateTime.UtcNow < _graceEnds
            ? snapshot with { Phase = "connecting", PhaseDetail = null, Summary = Loc.F("connection.connecting", snapshot.HostLabel) }
            : snapshot;

    /// <summary>The matrix chooser at the top of the pane: the shown matrix's name, a list of all of them, and a way to
    /// manage them. Hidden until a matrix has been added; rebuilt only when the list or the choice changes.</summary>
    private void ApplyMatrixPicker(Snapshot snapshot)
    {
        var signature = string.Join("|", snapshot.Matrices.Select(m => (m.Id, m.DisplayName, m.Selected)));
        if (signature == _matrixSignature) return;
        _matrixSignature = signature;

        _matrixPicker.Visibility = snapshot.Matrices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (snapshot.Matrices.Count == 0) return;

        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        content.Children.Add(new FontIcon { Glyph = "", FontSize = 14 });
        var label = Ui.Text(snapshot.SelectedMatrix?.DisplayName ?? Loc.T("matrix.switch"));
        label.TextTrimming = TextTrimming.CharacterEllipsis;
        content.Children.Add(label);
        _matrixPicker.Content = content;
        ToolTipService.SetToolTip(_matrixPicker, Loc.T("matrix.choose"));

        var menu = new MenuFlyout();
        foreach (var matrix in snapshot.Matrices)
        {
            var item = new RadioMenuFlyoutItem { Text = matrix.DisplayName, GroupName = "matrices", IsChecked = matrix.Selected };
            item.Click += async (_, _) =>
            {
                if (matrix.Selected) return;
                var result = await _core.SelectMatrixAsync(matrix.Id);
                if (result.Ok) BeginConnectionGrace();
                else await Dialogs.ErrorAsync(Loc.T("matrix.switchError"), result.Error);
            };
            menu.Items.Add(item);
        }
        menu.Items.Add(new MenuFlyoutSeparator());
        var manage = new MenuFlyoutItem { Text = Loc.T("matrix.manage") };
        manage.Click += (_, _) => SelectSettings();
        menu.Items.Add(manage);
        _matrixPicker.Flyout = menu;
    }

    /// <summary>Pushes the latest snapshot into every view, then shows the page that is selected.</summary>
    private void Refresh()
    {
        var snapshot = Displayed(_snapshot);
        ApplyMatrixPicker(snapshot);
        _statusBar.Apply(snapshot);
        _settings.Apply(snapshot);

        if (snapshot.IsConnected)
        {
            _routing.Apply(snapshot);
            _hardware.Apply(snapshot);
        }
        else
        {
            _connection.Apply(snapshot);
            // First run: go straight to where the address is entered.
            if (snapshot.Phase == "notConfigured" && _navigationReady && !_openedSettingsForSetup)
            {
                _openedSettingsForSetup = true;
                SelectSettings();
            }
        }
        ShowSelectedPage();
    }

    private void SelectSettings()
    {
        if (_navigation.SettingsItem != null) _navigation.SelectedItem = _navigation.SettingsItem;
    }

    private bool IsSettingsSelected => ReferenceEquals(_navigation.SelectedItem, _navigation.SettingsItem);

    private void ShowSelectedPage()
    {
        UIElement page;
        if (IsSettingsSelected) page = _settings;
        else if (ReferenceEquals(_navigation.SelectedItem, _aboutItem)) page = _about;
        else if (!_snapshot.IsConnected) page = _connection;
        else if (ReferenceEquals(_navigation.SelectedItem, _hardwareItem)) page = _hardware;
        else page = _routing;

        if (!ReferenceEquals(_content.Child, page)) _content.Child = page;
        UpdateBackButton();
    }

    private void UpdateBackButton() =>
        _titleBar.IsBackButtonEnabled = ReferenceEquals(_content.Child, _hardware) && _hardware.CanGoBack;

    private void Shutdown()
    {
        _updates.Dispose();
        // Disposing waits for any command still talking to the matrix; don't hold the window open for it.
        Task.Run(_core.Dispose).Wait(TimeSpan.FromSeconds(2));
    }
}
