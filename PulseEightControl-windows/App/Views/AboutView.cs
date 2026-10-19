using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;

namespace PulseEightControl.Views;

/// <summary>What the app is: name, version, who made it, its licence and where to find the source.</summary>
internal sealed class AboutView : UserControl
{
    private const string Repository = "https://github.com/bytefloater/pulseeight-control";

    public AboutView(string version)
    {
        var page = new StackPanel { Spacing = 8 };
        page.Children.Add(Ui.Header(Loc.T("about.title")));

        var name = new StackPanel { Spacing = 4, VerticalAlignment = VerticalAlignment.Center };
        name.Children.Add(Ui.Text(Loc.T("app.title"), "SubtitleTextBlockStyle"));
        name.Children.Add(Ui.Text(Loc.T("about.description"), secondary: true, wrap: true));

        // The logo beside the name (drawn at 72 and decoded at twice that, so it stays sharp on a high-DPI screen).
        var identity = new Grid { ColumnSpacing = 16, Padding = Ui.RowPadding };
        identity.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        identity.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        if (AppAssets.Find("Logo.png") is { } logoPath)
        {
            var logo = new Image
            {
                Width = 72, Height = 72, VerticalAlignment = VerticalAlignment.Center,
                Source = new BitmapImage(new Uri(logoPath)) { DecodePixelWidth = 144 },
            };
            AutomationProperties.SetName(logo, Loc.T("app.title"));
            identity.Children.Add(logo);
        }
        Grid.SetColumn(name, 1);
        identity.Children.Add(name);
        page.Children.Add(Ui.Card(identity));

        page.Children.Add(Ui.Card(
            Ui.Row(Loc.T("about.version"), version),
            Ui.Row(Loc.T("about.copyright"), Loc.T("about.copyrightValue")),
            Ui.Row(Loc.T("about.license"), Loc.T("about.licenseValue")),
            Ui.Row(Loc.T("about.sourceCode"), Link("github.com/bytefloater/pulseeight-control", Repository)),
            Ui.Row(Loc.T("about.reportIssue"), Link("github.com/bytefloater/pulseeight-control/issues", Repository + "/issues"))));

        var note = Ui.Text(Loc.T("about.independent"), "CaptionTextBlockStyle", secondary: true, wrap: true);
        note.Margin = new Thickness(2, 4, 0, 0);
        page.Children.Add(note);

        Content = Ui.Page(page);
    }

    private static HyperlinkButton Link(string text, string address) =>
        new() { Content = text, NavigateUri = new Uri(address), Padding = new Thickness(0) };
}
