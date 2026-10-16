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
    private readonly TextBox _host = new() { Width = 240, PlaceholderText = "192.168.1.150" };
    private readonly TextBox _port = new() { Width = 120 };
    private readonly TextBox _timeout = new() { Width = 120 };
    private readonly TextBox _poll = new() { Width = 120 };
    private readonly TextBox _detailPoll = new() { Width = 120 };
    private readonly PasswordBox _password = new() { Width = 240 };
    private readonly Button _removePassword = new() { Content = "Remove saved password" };
    private readonly Button _save = new() { Content = "Save and connect" };
    private readonly TextBlock _message = Ui.Text("", "CaptionTextBlockStyle", wrap: true);
    private readonly ComboBox _appearance = new() { MinWidth = 140 };
    private readonly ToggleSwitch _highlight = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly ToggleSwitch _statusBar = new() { OnContent = "", OffContent = "", MinWidth = 0 };
    private readonly TextBlock _passwordNote = Ui.Text("", "CaptionTextBlockStyle", secondary: true, wrap: true);

    private bool _loading;
    private bool _loadedOnce;

    public SettingsView(CoreClient core)
    {
        _core = core;
        foreach (var name in new[] { "Use system setting", "Light", "Dark" }) _appearance.Items.Add(name);
        _password.PlaceholderText = "Leave blank to keep the saved password";

        _save.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        _save.Click += async (_, _) => await SaveAsync();
        _removePassword.Click += async (_, _) => await RemovePasswordAsync();
        _appearance.SelectionChanged += async (_, _) =>
        {
            if (_loading || _appearance.SelectedIndex < 0) return;
            await _core.SetAppearanceAsync(Appearances[_appearance.SelectedIndex]);
        };
        _highlight.Toggled += async (_, _) => { if (!_loading) await _core.SetHighlightGridAsync(_highlight.IsOn); };
        _statusBar.Toggled += async (_, _) => { if (!_loading) await _core.SetShowStatusBarAsync(_statusBar.IsOn); };

        Content = Ui.Page(Build());
    }

    private UIElement Build()
    {
        var page = new StackPanel { Spacing = 4 };
        page.Children.Add(Ui.Header("Settings"));

        page.Children.Add(Ui.Section("Matrix", Ui.Card(
            Ui.Row("Address", _host, "Host name or IP address of the matrix"),
            Ui.Row("Port", _port),
            Ui.Row("Timeout", _timeout, "Seconds to wait for a reply"),
            Ui.Row("Refresh interval", _poll, "Seconds between status checks"),
            Ui.Row("Port detail interval", _detailPoll, "Seconds between port detail checks"))));

        page.Children.Add(Ui.Section("Administrator", Ui.Card(
            Ui.Row("Password", _password, "Needed to rename ports, change EDID profiles and use the front panel controls"),
            Ui.Row("Saved password", _removePassword, null))));
        page.Children.Add(_passwordNote);

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12, Margin = new Thickness(0, 8, 0, 0) };
        actions.Children.Add(_save);
        actions.Children.Add(_message);
        page.Children.Add(actions);

        page.Children.Add(Ui.Section("Appearance", Ui.Card(
            Ui.Row("Theme", _appearance),
            Ui.Row("Highlight row and column", _highlight, "Light up the grid under the pointer"),
            Ui.Row("Show status bar", _statusBar))));

        return page;
    }

    public void Apply(Snapshot snapshot)
    {
        _loading = true;
        try
        {
            var settings = snapshot.Settings;
            _appearance.SelectedIndex = Math.Max(0, Array.IndexOf(Appearances, settings.Appearance));
            _highlight.IsOn = settings.HighlightGrid;
            _statusBar.IsOn = settings.ShowStatusBar;
            _removePassword.IsEnabled = snapshot.AdminConfigured;
            _passwordNote.Text = snapshot.AdminConfigured
                ? "An admin password is saved on this PC."
                : "No admin password is saved. The app is read-only.";

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
            _message.Text = "Saved";
            _message.Foreground = Palette.Status(0);
        }
        else
        {
            _message.Text = result.Error ?? "Couldn't save the settings";
            _message.Foreground = Palette.Status(1);
        }
    }

    private async Task RemovePasswordAsync()
    {
        var confirm = new ContentDialog
        {
            Title = "Remove the saved password?",
            Content = Ui.Text("The app will become read-only until you enter the password again.", wrap: true),
            PrimaryButtonText = "Remove",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Close,
        };
        var removed = false;
        confirm.PrimaryButtonClick += (_, _) => removed = true;
        await Dialogs.ShowAsync(confirm);
        if (!removed) return;

        var result = await _core.RemoveAdminPasswordAsync();
        if (!result.Ok) await Dialogs.ErrorAsync("Couldn't remove the password", result.Error);
    }
}
