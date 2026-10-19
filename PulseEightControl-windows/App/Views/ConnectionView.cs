using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>Shown in place of the pages while there is no connection to the matrix.</summary>
internal sealed class ConnectionView : UserControl
{
    private readonly CoreClient _core;
    private readonly Action _openSettings;
    private readonly Action _connectionChanged;
    private bool _finding;
    private string? _findError; // why the last Find found nothing; kept across the redraws a snapshot causes
    private Snapshot? _last;

    public ConnectionView(CoreClient core, Action openSettings, Action connectionChanged)
    {
        _core = core;
        _openSettings = openSettings;
        _connectionChanged = connectionChanged;
    }

    public void Apply(Snapshot snapshot)
    {
        _last = snapshot;
        var panel = new StackPanel
        {
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            Spacing = 12, MaxWidth = 420,
        };

        string title, detail;
        switch (snapshot.Phase)
        {
            case "notConfigured":
                panel.Children.Add(new FontIcon { Glyph = "", FontSize = 40 });
                title = Loc.T("connection.addMatrix.title");
                detail = Loc.T("connection.addMatrix.detail");
                break;
            case "restarting":
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 40, Height = 40 });
                title = snapshot.Summary; // "Restarting <name>..."
                detail = Loc.T("connection.restartingDetail");
                break;
            case "connecting":
                panel.Children.Add(new ProgressRing { IsActive = true, Width = 40, Height = 40 });
                title = Loc.T("connection.connecting.title");
                detail = snapshot.Summary;
                break;
            default:
                panel.Children.Add(new FontIcon { Glyph = "", FontSize = 40 });
                title = Loc.T("connection.unreachable.title");
                detail = snapshot.PhaseDetail ?? snapshot.Summary;
                break;
        }

        var heading = Ui.Text(title, "SubtitleTextBlockStyle");
        heading.HorizontalAlignment = HorizontalAlignment.Center;
        var message = Ui.Text(detail, secondary: true, wrap: true);
        message.TextAlignment = TextAlignment.Center;
        panel.Children.Add(heading);
        panel.Children.Add(message);
        if (snapshot.Phase == "notConfigured" && _findError != null)
        {
            var failure = Ui.Text(_findError, "CaptionTextBlockStyle", wrap: true);
            failure.TextAlignment = TextAlignment.Center;
            failure.Foreground = Palette.Status(1);
            panel.Children.Add(failure);
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        if (snapshot.Phase == "restarting")
        {
            // Nothing to press: it comes back by itself.
        }
        else if (snapshot.Phase != "notConfigured")
        {
            var retry = new Button { Content = Loc.T("connection.tryAgain") };
            retry.Click += async (_, _) =>
            {
                _connectionChanged();
                await _core.RetryAsync();
            };
            buttons.Children.Add(retry);
        }
        else
        {
            var find = new Button
            {
                Content = Loc.T(_finding ? "connection.finding" : "connection.findMatrix"), IsEnabled = !_finding,
                Style = (Style)Application.Current.Resources["AccentButtonStyle"],
            };
            find.Click += async (_, _) => await FindAndConnectAsync();
            buttons.Children.Add(find);
        }
        var settings = new Button { Content = Loc.T("connection.openSettings") };
        settings.Click += (_, _) => _openSettings();
        buttons.Children.Add(settings);
        panel.Children.Add(buttons);

        Content = panel;
    }

    /// <summary>Asks which matrix is on this network and, if there is one, adds it and connects to it. A matrix
    /// already in the list for that address is shown instead of being added again.</summary>
    private async Task FindAndConnectAsync()
    {
        _finding = true;
        _findError = null;
        Redraw();
        try
        {
            var found = await _core.DiscoverAsync();
            if (found == null)
            {
                _findError = Loc.T("matrix.noneFound");
                return;
            }
            var known = _last?.Matrices.FirstOrDefault(m => m.Host == found.Host && m.Port == found.Port);
            string? id = known?.Id;
            if (id == null)
            {
                var saved = await _core.SaveMatrixAsync(null, "", found.Host, found.Port.ToString(), "10", "5", "20", null);
                if (!saved.Ok) { _findError = saved.Error; return; }
                id = saved.Value;
            }
            var selected = await _core.SelectMatrixAsync(id!);
            if (!selected.Ok) { _findError = selected.Error; return; }
            _connectionChanged();
        }
        catch (InvalidOperationException failure) { _findError = failure.Message; }
        finally
        {
            _finding = false;
            Redraw();
        }
    }

    private void Redraw()
    {
        if (_last != null) Apply(_last);
    }
}
