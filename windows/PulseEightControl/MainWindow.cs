using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using PulseEight.Core;
using PulseEightControl.Views;
using Windows.Graphics;
using Windows.System;

namespace PulseEightControl;

public sealed class MainWindow : Window
{
    private readonly CoreClient _core = new();
    private readonly NavigationView _navigation = new();
    private readonly Border _content = new();
    private readonly StatusBarView _statusBar = new();
    private readonly NavigationViewItem _routingItem;
    private readonly NavigationViewItem _hardwareItem;
    private readonly RoutingView _routing;
    private readonly HardwareView _hardware;
    private readonly SettingsView _settings;
    private readonly ConnectionView _connection;
    private readonly Grid _root = new();

    private Snapshot _snapshot = null!;
    private bool _openedSettingsForSetup;
    private bool _navigationReady; // NavigationView's built-in Settings item exists only once it has loaded

    public MainWindow()
    {
        _snapshot = _core.Snapshot;
        Title = "PulseEight Control";
        SystemBackdrop = new MicaBackdrop();
        AppWindow.Resize(new SizeInt32(1100, 780));

        _routing = new RoutingView(_core, port => _ = PortDialog.ShowAsync(_core, port, _snapshot));
        _hardware = new HardwareView(_core, port => _ = PortDialog.ShowAsync(_core, port, _snapshot));
        _settings = new SettingsView(_core);
        _connection = new ConnectionView(_core, SelectSettings);

        _routingItem = new NavigationViewItem { Content = "Routing", Tag = "routing", Icon = new FontIcon { Glyph = "" } };
        _hardwareItem = new NavigationViewItem { Content = "Hardware", Tag = "hardware", Icon = new FontIcon { Glyph = "" } };

        _navigation.PaneDisplayMode = NavigationViewPaneDisplayMode.Left;
        _navigation.IsBackButtonVisible = NavigationViewBackButtonVisible.Collapsed;
        _navigation.IsPaneToggleButtonVisible = false;
        _navigation.IsPaneOpen = true;
        _navigation.OpenPaneLength = 200;
        _navigation.IsSettingsVisible = true;
        _navigation.MenuItems.Add(_routingItem);
        _navigation.MenuItems.Add(_hardwareItem);
        _navigation.Content = _content;
        _navigation.SelectionChanged += (_, _) => ShowSelectedPage();

        _root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        _root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        _root.Children.Add(_navigation);
        Grid.SetRow(_statusBar, 1);
        _root.Children.Add(_statusBar);
        Content = _root;

        AddShortcut(VirtualKey.Number1, () => _navigation.SelectedItem = _routingItem);
        AddShortcut(VirtualKey.Number2, () => _navigation.SelectedItem = _hardwareItem);
        AddShortcut(VirtualKey.R, () => _ = _core.RetryAsync());
        AddShortcut(VirtualKey.Number3, SelectSettings);

        _root.Loaded += (_, _) =>
        {
            Dialogs.Root = _root.XamlRoot;
            Palette.Update(_root.ActualTheme);
            _routing.Invalidate();
            _hardware.Invalidate();
            Refresh();
        };
        _navigation.Loaded += (_, _) =>
        {
            _navigationReady = true;
            Refresh();
        };
        _root.ActualThemeChanged += (_, _) =>
        {
            Palette.Update(_root.ActualTheme);
            _routing.Invalidate();
            _hardware.Invalidate();
            Refresh();
        };

        Closed += (_, _) => Shutdown();

        Palette.Update(ElementTheme.Light);
        _navigation.SelectedItem = _routingItem;
        _core.Changed += snapshot => DispatcherQueue.TryEnqueue(() => OnChanged(snapshot));
        ApplyTheme(_snapshot);
        Refresh();
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

    /// <summary>Pushes the latest snapshot into every view, then shows the page that is selected.</summary>
    private void Refresh()
    {
        var snapshot = _snapshot;
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
        else if (!_snapshot.IsConnected) page = _connection;
        else if (ReferenceEquals(_navigation.SelectedItem, _hardwareItem)) page = _hardware;
        else page = _routing;

        if (!ReferenceEquals(_content.Child, page)) _content.Child = page;
    }

    private void Shutdown()
    {
        // Disposing waits for any command still talking to the matrix; don't hold the window open for it.
        Task.Run(_core.Dispose).Wait(TimeSpan.FromSeconds(2));
    }
}
