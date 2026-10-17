using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using PulseEight.Core;

namespace PulseEightControl.Views;

/// <summary>Shown in place of the pages while there is no connection to the matrix.</summary>
internal sealed class ConnectionView : UserControl
{
    private readonly CoreClient _core;
    private readonly Action _openSettings;

    public ConnectionView(CoreClient core, Action openSettings)
    {
        _core = core;
        _openSettings = openSettings;
    }

    public void Apply(Snapshot snapshot)
    {
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

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, HorizontalAlignment = HorizontalAlignment.Center };
        if (snapshot.Phase != "notConfigured")
        {
            var retry = new Button { Content = Loc.T("connection.tryAgain") };
            retry.Click += async (_, _) => await _core.RetryAsync();
            buttons.Children.Add(retry);
        }
        var settings = new Button { Content = Loc.T("connection.openSettings") };
        if (snapshot.Phase == "notConfigured") settings.Style = (Style)Application.Current.Resources["AccentButtonStyle"];
        settings.Click += (_, _) => _openSettings();
        buttons.Children.Add(settings);
        panel.Children.Add(buttons);

        Content = panel;
    }
}
