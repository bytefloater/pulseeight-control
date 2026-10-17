using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Updates;

namespace PulseEightControl.Updates;

internal enum UpdateDecision { Later, Skipped, Installing }

/// <summary>
/// The "update available" window: what's new, then Install and restart / Later / Skip this version. Installing
/// downloads inside the dialog (progress bar, errors shown in place) and ends with the app closing for the installer.
/// </summary>
internal static class UpdateDialog
{
    public static async Task<UpdateDecision> ShowAsync(IUpdateService updates, UpdateOffer offer, string installedVersion)
    {
        var decision = UpdateDecision.Later;
        var working = false;     // downloading or installing: the dialog stays until that finishes
        var installing = false;  // past the download: it can no longer be cancelled
        using var cancellation = new CancellationTokenSource();

        var notes = ReleaseNotesText.FromHtml(offer.ReleaseNotesHtml);
        var body = new StackPanel { Spacing = 12, MinWidth = 420, MaxWidth = 520 };
        body.Children.Add(Ui.Text(Loc.F("update.available", offer.DisplayVersion, installedVersion), wrap: true));

        body.Children.Add(Ui.Text(Loc.T("update.notes"), "BodyStrongTextBlockStyle"));
        if (notes.Length > 0)
        {
            body.Children.Add(new ScrollViewer
            {
                MaxHeight = 220,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = new TextBlock { Text = notes, TextWrapping = TextWrapping.Wrap, IsTextSelectionEnabled = true },
            });
        }
        else if (Uri.TryCreate(offer.ReleaseNotesUrl, UriKind.Absolute, out var link) && link.Scheme == Uri.UriSchemeHttps)
        {
            body.Children.Add(new HyperlinkButton { Content = link.Host, NavigateUri = link, Padding = new Thickness(0) });
        }
        else
        {
            body.Children.Add(Ui.Text(Loc.T("update.noNotes"), secondary: true, wrap: true));
        }

        var progress = new ProgressBar { Minimum = 0, Maximum = 100, Visibility = Visibility.Collapsed };
        var status = Ui.Text("", "CaptionTextBlockStyle", secondary: true, wrap: true);
        status.Visibility = Visibility.Collapsed;
        var error = new InfoBar { Severity = InfoBarSeverity.Error, IsOpen = false, IsClosable = false };
        body.Children.Add(progress);
        body.Children.Add(status);
        body.Children.Add(error);

        var dialog = new ContentDialog
        {
            Title = Loc.T("update.title"),
            Content = body,
            PrimaryButtonText = Loc.T("update.install"),
            CloseButtonText = Loc.T("update.later"),
            DefaultButton = ContentDialogButton.Primary,
        };
        if (!offer.IsCritical) dialog.SecondaryButtonText = Loc.T("update.skip");

        void SetWorking(bool on)
        {
            working = on;
            dialog.IsPrimaryButtonEnabled = !on;
            dialog.IsSecondaryButtonEnabled = !on;
            progress.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
            status.Visibility = on ? Visibility.Visible : Visibility.Collapsed;
        }

        dialog.SecondaryButtonClick += (_, _) =>
        {
            updates.Skip(offer);
            decision = UpdateDecision.Skipped;
        };

        dialog.PrimaryButtonClick += async (_, args) =>
        {
            args.Cancel = true; // stay open: the download and any error are shown here
            var deferral = args.GetDeferral();
            try
            {
                error.IsOpen = false;
                progress.IsIndeterminate = offer.SizeBytes <= 0;
                progress.Value = 0;
                status.Text = Loc.F("update.downloading", offer.DisplayVersion);
                SetWorking(true);

                await updates.DownloadAsync(offer, new Progress<UpdateProgress>(p =>
                {
                    if (p.TotalBytes > 0)
                    {
                        progress.IsIndeterminate = false;
                        progress.Value = p.Percent;
                    }
                }), cancellation.Token);

                installing = true;
                progress.IsIndeterminate = true;
                status.Text = Loc.T("update.installing");
                decision = UpdateDecision.Installing;
                await updates.InstallAsync(offer);
                // The app is asked to close (UpdateService.ExitRequested) and the installer takes over from here.
            }
            catch (OperationCanceledException)
            {
                SetWorking(false);
            }
            catch (Exception exception)
            {
                installing = false;
                decision = UpdateDecision.Later;
                SetWorking(false);
                error.Message = Loc.F("update.downloadFailed", exception.Message);
                error.IsOpen = true;
            }
            finally { deferral.Complete(); }
        };

        dialog.Closing += (_, args) =>
        {
            if (installing) args.Cancel = true;            // the installer has started; closing now would strand it
            else if (working) cancellation.Cancel();       // closing during the download abandons it
        };

        await Dialogs.ShowAsync(dialog);
        return decision;
    }
}
