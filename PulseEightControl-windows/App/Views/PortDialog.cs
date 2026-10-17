using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>Details of one port, with rename and (for inputs) EDID profile when an admin password is saved.</summary>
internal static class PortDialog
{
    public static async Task ShowAsync(CoreClient core, PortSnapshot port, Snapshot snapshot)
    {
        var admin = snapshot.AdminConfigured;
        var body = new StackPanel { Spacing = 12, MinWidth = 380 };

        var status = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        status.Children.Add(Ui.Dot(Palette.Status(port.Status)));
        status.Children.Add(Ui.Text(port.StatusLabel));
        if (port.SourceName != null) status.Children.Add(Ui.Text(Loc.F("portDialog.from", port.SourceName), secondary: true));
        body.Children.Add(status);

        TextBox? nameBox = null;
        ComboBox? edidBox = null;
        var error = Ui.Text("", wrap: true);
        error.Foreground = Palette.Status(1);
        error.Visibility = Visibility.Collapsed;

        if (admin)
        {
            nameBox = new TextBox { Header = Loc.T("portDialog.name"), Text = port.Name, MaxLength = 13 };
            body.Children.Add(nameBox);

            if (port.IsInput && snapshot.EdidProfiles.Count > 0)
            {
                edidBox = new ComboBox { Header = Loc.T("portDialog.edidProfile"), HorizontalAlignment = HorizontalAlignment.Stretch };
                foreach (var profile in snapshot.EdidProfiles) edidBox.Items.Add(profile.Name);
                var current = snapshot.EdidProfiles.ToList().FindIndex(p => p.Id == port.EdidProfile);
                edidBox.SelectedIndex = current;
                body.Children.Add(edidBox);
            }
        }

        if (port.Details.Count > 0)
        {
            var rows = new Grid { ColumnSpacing = 16, RowSpacing = 4 };
            rows.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            rows.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            for (var i = 0; i < port.Details.Count; i++)
            {
                rows.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
                var label = Ui.Text(port.Details[i].Label, "CaptionTextBlockStyle", secondary: true);
                var value = Ui.Text(port.Details[i].Value, "CaptionTextBlockStyle", wrap: true);
                value.IsTextSelectionEnabled = true;
                Grid.SetRow(label, i);
                Grid.SetRow(value, i);
                Grid.SetColumn(value, 1);
                rows.Children.Add(label);
                rows.Children.Add(value);
            }
            body.Children.Add(rows);
        }

        if (!admin)
            body.Children.Add(Ui.Text(Loc.T("portDialog.needAdmin"), "CaptionTextBlockStyle", secondary: true, wrap: true));
        body.Children.Add(error);

        var dialog = new ContentDialog
        {
            Title = Loc.F("portDialog.title", Loc.T(port.IsInput ? "port.input" : "port.output"), port.Number),
            Content = new ScrollViewer { Content = body, VerticalScrollBarVisibility = ScrollBarVisibility.Auto },
            CloseButtonText = Loc.T(admin ? "common.cancel" : "common.close"),
            DefaultButton = admin ? ContentDialogButton.Primary : ContentDialogButton.Close,
        };
        if (admin) dialog.PrimaryButtonText = Loc.T("common.save");

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                string? failure = null;
                var name = nameBox?.Text.Trim() ?? port.Name;
                if (name != port.Name)
                {
                    var rename = await core.RenamePortAsync(port, name);
                    if (!rename.Ok) failure = rename.Error;
                }
                if (failure == null && edidBox is { SelectedIndex: >= 0 })
                {
                    var profile = snapshot.EdidProfiles[edidBox.SelectedIndex];
                    if (profile.Id != port.EdidProfile)
                    {
                        var edid = await core.SetEdidAsync(port.Bay, profile.Id);
                        if (!edid.Ok) failure = edid.Error;
                    }
                }
                if (failure != null)
                {
                    error.Text = failure;
                    error.Visibility = Visibility.Visible;
                    args.Cancel = true;
                }
            }
            finally { deferral.Complete(); }
        };

        await Dialogs.ShowAsync(dialog);
    }
}
