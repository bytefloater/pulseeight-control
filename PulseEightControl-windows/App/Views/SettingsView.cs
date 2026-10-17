using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>Matrix address, admin password and appearance. Appearance applies at once; the
/// connection details are saved together with the button.</summary>
internal sealed class SettingsView : UserControl
{
    private static readonly string[] Appearances = ["system", "light", "dark"];

    private readonly CoreClient _core;
    private readonly TextBox _host = new() { Width = 200, PlaceholderText = "192.168.1.150" };
    private readonly TextBox _port = new() { Width = 120 };
    private readonly TextBox _timeout = new() { Width = 120 };
    private readonly TextBox _poll = new() { Width = 120 };
    private readonly TextBox _detailPoll = new() { Width = 120 };
    private readonly PasswordBox _password = new() { Width = 260 };
    private readonly Button _removePassword = new() { Content = Loc.T("settings.removePassword") };
    private readonly Button _save = new() { Content = Loc.T("settings.save") };
    private readonly TextBlock _message = Ui.Text("", "CaptionTextBlockStyle", wrap: true);
    private readonly ComboBox _appearance = new() { MinWidth = 140 };
    private readonly ComboBox _language = new() { MinWidth = 140 };
    private readonly List<string> _languageCodes = []; // parallel to _language.Items: "system", then each language
    private readonly ToggleSwitch _highlight = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly ToggleSwitch _statusBar = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly TextBlock _passwordNote = Ui.Text("", "CaptionTextBlockStyle", secondary: true, wrap: true);

    private bool _loading;
    private bool _loadedOnce;

    public SettingsView(CoreClient core)
    {
        _core = core;
        foreach (var key in new[] { "theme.system", "theme.light", "theme.dark" }) _appearance.Items.Add(Loc.T(key));
        _password.PlaceholderText = Loc.T("settings.password.placeholder");

        _save.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _save.Click += async (_, _) => await SaveAsync();
        _removePassword.Click += async (_, _) => await RemovePasswordAsync();
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

        Content = Ui.Page(Build());
    }


    private UIElement Build()
    {
        var page = new StackPanel { Spacing = 4 };
        page.Children.Add(Ui.Header(Loc.T("settings.title")));

        page.Children.Add(Ui.Columns(
            Ui.Section(Loc.T("settings.matrix"), Ui.Card(
                Ui.Row(Loc.T("settings.address"), _host, Loc.T("settings.address.caption")),
                Ui.Row(Loc.T("settings.port"), _port))),
            Ui.Section(Loc.T("settings.polling"), Ui.Card(
                Ui.Row(Loc.T("settings.timeout"), _timeout, Loc.T("settings.timeout.caption")),
                Ui.Row(Loc.T("settings.refresh"), _poll, Loc.T("settings.refresh.caption")),
                Ui.Row(Loc.T("settings.detailInterval"), _detailPoll, Loc.T("settings.detailInterval.caption"))))));

        page.Children.Add(Ui.Section(Loc.T("settings.administrator"), Ui.Card(
            Ui.Row(Loc.T("settings.password"), _password, Loc.T("settings.password.caption")),
            Ui.Row(Loc.T("settings.savedPassword"), _removePassword, null))));
        page.Children.Add(_passwordNote);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(0, 8, 0, 0) };
        actions.Children.Add(_save);
        actions.Children.Add(_message);
        page.Children.Add(actions);

        page.Children.Add(Ui.Section(Loc.T("settings.appearance"), Ui.Card(
            Ui.Row(Loc.T("settings.theme"), _appearance),
            Ui.Row(Loc.T("settings.language"), _language, Loc.T("settings.language.caption")),
            Ui.Row(Loc.T("settings.highlight"), _highlight, Loc.T("settings.highlight.caption")),
            Ui.Row(Loc.T("settings.statusBar"), _statusBar))));

        return page;
    }

    public void Apply(Snapshot snapshot)
    {
        _loading = true;
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
            _removePassword.IsEnabled = snapshot.AdminConfigured;
            _passwordNote.Text = snapshot.AdminConfigured
                ? Loc.T("settings.passwordSaved")
                : Loc.T("settings.passwordNone");

            // Don't overwrite what's being typed; fill the form once, and again after saving.
            if (!_loadedOnce)
            {
                _loadedOnce = true;
                Reload(settings);
            }
        }
        finally { _loading = false; }
    }

    private void Reload(SettingsSnapshot settings)
    {
        _host.Text = settings.Host ?? "";
        _port.Text = settings.Port.ToString();
        _timeout.Text = settings.Timeout.ToString();
        _poll.Text = settings.PollInterval.ToString();
        _detailPoll.Text = settings.DetailPollInterval.ToString();
        _password.Password = "";
    }

    private async Task SaveAsync()
    {
        _save.IsEnabled = false;
        _message.Text = "";
        var result = await _core.SaveSettingsAsync(
            _host.Text, _port.Text, _timeout.Text, _poll.Text, _detailPoll.Text, _password.Password);
        _save.IsEnabled = true;
        if (result.Ok)
        {
            _password.Password = "";
            _message.Text = Loc.T("settings.saved");
            _message.Foreground = Palette.Status(0);
        }
        else
        {
            _message.Text = result.Error ?? Loc.T("settings.saveError");
            _message.Foreground = Palette.Status(1);
        }
    }

    private async Task RemovePasswordAsync()
    {
        var confirm = new ContentDialog
        {
            Title = Loc.T("settings.removeDialog.title"),
            Content = Ui.Text(Loc.T("settings.removeDialog.body"), wrap: true),
            PrimaryButtonText = Loc.T("common.remove"),
            CloseButtonText = Loc.T("common.cancel"),
            DefaultButton = ContentDialogButton.Close,
        };
        var removed = false;
        confirm.PrimaryButtonClick += (_, _) => removed = true;
        await Dialogs.ShowAsync(confirm);
        if (!removed) return;

        var result = await _core.RemoveAdminPasswordAsync();
        if (!result.Ok) await Dialogs.ErrorAsync(Loc.T("settings.removeError"), result.Error);
    }
}
