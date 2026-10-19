using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;
using PulseEightControl.Updates;

namespace PulseEightControl.Views;

/// <summary>The list of matrices (pick one to show it; add, edit and remove them in a dialog), then
/// appearance and updates. Everything but the matrix dialog applies at once.</summary>
internal sealed class SettingsView : UserControl
{
    private static readonly string[] Appearances = ["system", "light", "dark"];

    private readonly CoreClient _core;
    private readonly UpdateController _updates;
    private readonly Action _connectionChanged;
    private readonly StackPanel _matrixList = new();
    private readonly Button _addMatrix = new() { Content = Loc.T("settings.connections.add") };
    private string _matricesSignature = "";
    private readonly ComboBox _appearance = new() { MinWidth = 140 };
    private readonly ComboBox _language = new() { MinWidth = 140 };
    private readonly List<string> _languageCodes = []; // parallel to _language.Items: "system", then each language
    private readonly ToggleSwitch _highlight = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly ToggleSwitch _statusBar = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly ToggleSwitch _autoUpdates = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly Button _checkNow = new() { Content = Loc.T("settings.updates.checkNow") };
    private readonly TextBlock _updateStatus = Ui.Text("", "CaptionTextBlockStyle", secondary: true, wrap: true);

    private bool _loading;
    private Snapshot? _snapshot;

    public SettingsView(CoreClient core, UpdateController updates, Action connectionChanged)
    {
        _core = core;
        _updates = updates;
        _connectionChanged = connectionChanged;
        foreach (var key in new[] { "theme.system", "theme.light", "theme.dark" }) _appearance.Items.Add(Loc.T(key));
        _addMatrix.Click += async (_, _) => await MatrixDialog.ShowAsync(_core, null, _connectionChanged);
        _appearance.SelectionChanged += async (_, _) =>
        {
            if (_loading || _appearance.SelectedIndex < 0) return;
            await _core.SetAppearanceAsync(Appearances[_appearance.SelectedIndex]);
        };
        _language.SelectionChanged += async (_, _) =>
        {
            if (_loading || _language.SelectedIndex < 0 || _language.SelectedIndex >= _languageCodes.Count) return;
            await _core.SetLanguageAsync(_languageCodes[_language.SelectedIndex]);
        };
        _highlight.Toggled += async (_, _) => { if (!_loading) await _core.SetHighlightGridAsync(_highlight.IsOn); };
        _statusBar.Toggled += async (_, _) => { if (!_loading) await _core.SetShowStatusBarAsync(_statusBar.IsOn); };
        _autoUpdates.Toggled += async (_, _) => { if (!_loading) await _core.SetCheckForUpdatesAsync(_autoUpdates.IsOn); };
        _checkNow.Click += async (_, _) => await _updates.CheckNowAsync();

        Content = Ui.Page(Build());
    }


    private UIElement Build()
    {
        var page = new StackPanel { Spacing = 8 };
        page.Children.Add(Ui.Header(Loc.T("settings.title")));

        var caption = Ui.Text(Loc.T("settings.connections.caption"), "CaptionTextBlockStyle", secondary: true, wrap: true);
        caption.Margin = new Thickness(2, 0, 0, 0);
        var add = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 4, 0, 0) };
        add.Children.Add(_addMatrix);
        page.Children.Add(Ui.Section(Loc.T("settings.connections"), _matrixList, first: true));
        page.Children.Add(add);
        page.Children.Add(caption);

        page.Children.Add(Ui.Section(Loc.T("settings.appearance"), Ui.Card(
            Ui.Row(Loc.T("settings.theme"), _appearance),
            Ui.Row(Loc.T("settings.language"), _language, Loc.T("settings.language.caption")),
            Ui.Row(Loc.T("settings.highlight"), _highlight, Loc.T("settings.highlight.caption")),
            Ui.Row(Loc.T("settings.statusBar"), _statusBar))));

        page.Children.Add(Ui.Section(Loc.T("settings.updates"), Ui.Card(
            Ui.Row(Loc.T("settings.updates.auto"), _autoUpdates, Loc.T("settings.updates.auto.caption")),
            Ui.Row(Loc.T("settings.updates.checkNow"), _checkNow, null))));
        page.Children.Add(_updateStatus);

        return page;
    }

    public void Apply(Snapshot snapshot)
    {
        _loading = true;
        _snapshot = snapshot;
        try
        {
            var settings = snapshot.Settings;
            _appearance.SelectedIndex = Math.Max(0, Array.IndexOf(Appearances, settings.Appearance));
            if (_languageCodes.Count == 0)
            {
                _languageCodes.Add("system");
                _language.Items.Add(Loc.T("language.system"));
                foreach (var language in snapshot.Languages)
                {
                    _languageCodes.Add(language.Code);
                    _language.Items.Add(language.Name);
                }
            }
            _language.SelectedIndex = Math.Max(0, _languageCodes.IndexOf(settings.Language));
            _highlight.IsOn = settings.HighlightGrid;
            _statusBar.IsOn = settings.ShowStatusBar;
            _autoUpdates.IsOn = settings.CheckForUpdates;
            ShowMatrices(snapshot);
        }
        finally { _loading = false; }
        ShowUpdateState();
    }

    /// <summary>Version and last check, or why there is nothing to check. Called with every snapshot and
    /// whenever the updater's state changes.</summary>
    public void ShowUpdateState()
    {
        var available = _updates.IsAvailable;
        _autoUpdates.IsEnabled = available;
        _checkNow.IsEnabled = available && !_updates.Busy;
        _updateStatus.Text = !available
            ? Loc.T("settings.updates.unavailable")
            : Loc.F("settings.updates.version", _updates.InstalledVersion) + "  \u00b7  " +
              (_updates.LastChecked is { } checkedAt
                  ? Loc.F("settings.updates.lastChecked", checkedAt.ToLocalTime().ToString("g"))
                  : Loc.T("settings.updates.neverChecked"));
    }

    /// <summary>The list of matrices, rebuilt only when something in it changed (it is rebuilt from every snapshot otherwise).</summary>
    private void ShowMatrices(Snapshot snapshot)
    {
        var signature = string.Join("|", snapshot.Matrices); // a record prints every field
        if (signature == _matricesSignature) return;
        _matricesSignature = signature;

        _matrixList.Children.Clear();
        if (snapshot.Matrices.Count == 0)
        {
            _matrixList.Children.Add(Ui.Card(Ui.Row(Loc.T("settings.connections.none"), "")));
            return;
        }
        _matrixList.Children.Add(Ui.Card(snapshot.Matrices.Select(MatrixRow).ToArray()));
    }

    /// <summary>One matrix: the tick and its name pick it, Edit opens its dialog.</summary>
    private UIElement MatrixRow(MatrixSnapshot matrix)
    {
        var line = new Grid { ColumnSpacing = 12, MinHeight = Ui.RowMinHeight, Padding = Ui.RowPadding };
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        line.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var names = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        names.Children.Add(Ui.Text(matrix.DisplayName));
        if (matrix.DisplayName != matrix.Address)
            names.Children.Add(Ui.Text(matrix.Address, "CaptionTextBlockStyle", secondary: true));

        // A radio button is the standard way to say "this one of several", and is clear in both themes. It has no
        // content of its own: a radio button puts its circle level with the first line of its content, and the
        // circle belongs level with the middle of the name and address together.
        var pick = new RadioButton
        {
            GroupName = "matrices", MinWidth = 0, VerticalAlignment = VerticalAlignment.Center, IsChecked = matrix.Selected,
        };
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(pick, matrix.DisplayName);
        ToolTipService.SetToolTip(pick, Loc.T(matrix.Selected ? "settings.connections.shown" : "settings.connections.show"));
        pick.Checked += async (_, _) => await SelectAsync(matrix);
        names.Background = Palette.Transparent; // so the whole name area takes the click
        names.Tapped += async (_, _) => await SelectAsync(matrix);
        Grid.SetColumn(names, 1);

        var edit = new Button { Content = Loc.T("settings.connections.edit"), VerticalAlignment = VerticalAlignment.Center };
        edit.Click += async (_, _) => await MatrixDialog.ShowAsync(_core, matrix, _connectionChanged);
        Grid.SetColumn(edit, 2);

        line.Children.Add(pick);
        line.Children.Add(names);
        line.Children.Add(edit);
        return line;
    }

    private async Task SelectAsync(MatrixSnapshot matrix)
    {
        if (matrix.Selected) return;
        var result = await _core.SelectMatrixAsync(matrix.Id);
        if (result.Ok) _connectionChanged();
        else
        {
            await Dialogs.ErrorAsync(Loc.T("matrix.switchError"), result.Error);
            if (_snapshot != null)
            {
                _matricesSignature = ""; // put the radio buttons back to what is really selected
                ShowMatrices(_snapshot);
            }
        }
    }
}
