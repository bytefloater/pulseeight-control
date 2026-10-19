using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>Adds a matrix, or changes one: name, address (with Find), timings and admin password.
/// Nothing is saved until Save; a refused value is explained in the dialog, which stays open.</summary>
internal static class MatrixDialog
{
    /// <param name="matrix">The matrix to change, or null to add one.</param>
    /// <param name="changed">Called after a matrix was saved or removed, so the window can start a fresh connection attempt.</param>
    public static async Task ShowAsync(CoreClient core, MatrixSnapshot? matrix, Action changed)
    {
        var name = new TextBox { Header = Loc.T("matrix.name"), PlaceholderText = "Lounge", Text = matrix?.Name ?? "" };
        var host = new TextBox { Header = Loc.T("settings.address"), PlaceholderText = "192.168.1.150", Text = matrix?.Host ?? "", HorizontalAlignment = HorizontalAlignment.Stretch };
        var find = new Button { Content = Loc.T("matrix.find"), VerticalAlignment = VerticalAlignment.Bottom };
        ToolTipService.SetToolTip(find, Loc.T("matrix.find.caption"));
        var port = new TextBox { Header = Loc.T("settings.port"), PlaceholderText = "80", Text = (matrix?.Port ?? 80).ToString() };
        var timeout = new TextBox { Header = Loc.T("settings.timeout"), PlaceholderText = "10", Text = (matrix?.Timeout ?? 10).ToString() };
        var poll = new TextBox { Header = Loc.T("settings.refresh"), PlaceholderText = "5", Text = (matrix?.PollInterval ?? 5).ToString() };
        var detailPoll = new TextBox { Header = Loc.T("settings.detailInterval"), PlaceholderText = "20", Text = (matrix?.DetailPollInterval ?? 20).ToString() };
        var password = new PasswordBox
        {
            Header = Loc.T("settings.password"),
            PlaceholderText = Loc.T(matrix?.AdminPasswordSaved == true ? "matrix.passwordSaved" : "matrix.passwordOptional"),
        };
        var clearPassword = new CheckBox
        {
            Content = Loc.T("matrix.clearPassword"),
            Visibility = matrix?.AdminPasswordSaved == true ? Visibility.Visible : Visibility.Collapsed,
        };
        clearPassword.Checked += (_, _) => password.IsEnabled = false;
        clearPassword.Unchecked += (_, _) => password.IsEnabled = true;

        var message = Ui.Text("", "CaptionTextBlockStyle", wrap: true);
        message.Visibility = Visibility.Collapsed;
        void Say(string text, bool isError)
        {
            message.Text = text;
            message.Foreground = Palette.Status(isError ? 1 : 0);
            message.Visibility = Visibility.Visible;
        }

        var addressRow = new Grid { ColumnSpacing = 8 };
        addressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        addressRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        addressRow.Children.Add(host);
        Grid.SetColumn(find, 1);
        addressRow.Children.Add(find);

        var timings = new Grid { ColumnSpacing = 8, RowSpacing = 12 };
        timings.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        timings.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        timings.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        timings.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        foreach (var (box, row, column) in new[] { (port, 0, 0), (timeout, 0, 1), (poll, 1, 0), (detailPoll, 1, 1) })
        {
            box.HorizontalAlignment = HorizontalAlignment.Stretch;
            Grid.SetRow(box, row);
            Grid.SetColumn(box, column);
            timings.Children.Add(box);
        }

        var body = new StackPanel { Spacing = 12, MinWidth = 420 };
        body.Children.Add(name);
        body.Children.Add(addressRow);
        body.Children.Add(timings);
        body.Children.Add(password);
        body.Children.Add(clearPassword);
        body.Children.Add(message);

        var dialog = new ContentDialog
        {
            Title = Loc.T(matrix == null ? "matrix.addTitle" : "matrix.editTitle"),
            PrimaryButtonText = Loc.T("common.save"),
            CloseButtonText = Loc.T("common.cancel"),
            DefaultButton = ContentDialogButton.Primary,
        };

        if (matrix != null)
        {
            // Removing asks twice, in the dialog, because only one dialog can be open at a time.
            var remove = new Button { Content = Loc.T("matrix.remove"), HorizontalAlignment = HorizontalAlignment.Left };
            var confirm = new StackPanel { Spacing = 8, Visibility = Visibility.Collapsed };
            var sure = new Button { Content = Loc.T("common.remove"), Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            var keep = new Button { Content = Loc.T("matrix.keep") };
            var choices = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            choices.Children.Add(sure);
            choices.Children.Add(keep);
            confirm.Children.Add(Ui.Text(Loc.F("matrix.removeConfirm", matrix.DisplayName), wrap: true));
            confirm.Children.Add(choices);

            remove.Click += (_, _) => { remove.Visibility = Visibility.Collapsed; confirm.Visibility = Visibility.Visible; };
            keep.Click += (_, _) => { confirm.Visibility = Visibility.Collapsed; remove.Visibility = Visibility.Visible; };
            sure.Click += async (_, _) =>
            {
                sure.IsEnabled = false;
                var result = await core.RemoveMatrixAsync(matrix.Id);
                if (result.Ok)
                {
                    changed();
                    dialog.Hide();
                }
                else
                {
                    sure.IsEnabled = true;
                    Say(result.Error ?? Loc.T("matrix.removeError"), true);
                }
            };
            body.Children.Add(remove);
            body.Children.Add(confirm);
        }

        find.Click += async (_, _) =>
        {
            find.IsEnabled = false;
            find.Content = Loc.T("matrix.finding");
            message.Visibility = Visibility.Collapsed;
            try
            {
                var found = await core.DiscoverAsync();
                if (found == null) Say(Loc.T("matrix.noneFound"), true);
                else
                {
                    host.Text = found.Host;
                    port.Text = found.Port.ToString();
                    Say(Loc.F("matrix.found", found.Host), false);
                }
            }
            catch (InvalidOperationException failure) { Say(failure.Message, true); }
            finally
            {
                find.Content = Loc.T("matrix.find");
                find.IsEnabled = true;
            }
        };

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                var result = await core.SaveMatrixAsync(
                    matrix?.Id, name.Text, host.Text, port.Text, timeout.Text, poll.Text, detailPoll.Text,
                    password.Password, clearPassword.IsChecked == true);
                if (result.Ok) changed();
                else
                {
                    Say(result.Error ?? Loc.T("settings.saveError"), true);
                    args.Cancel = true;
                }
            }
            finally { deferral.Complete(); }
        };

        dialog.Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        await Dialogs.ShowAsync(dialog);
    }
}
