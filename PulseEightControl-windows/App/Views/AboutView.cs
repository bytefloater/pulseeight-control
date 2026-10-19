using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PulseEightControl.Views;

/// <summary>What the app is: name, version, who made it, its licence and where to find the source.</summary>
internal sealed class AboutView : UserControl
{
    private const string Repository = "https://github.com/bytefloater/pulseeight-control";

    public AboutView(string version)
    {
        var page = new StackPanel { Spacing = 8 };
        page.Children.Add(Ui.Header(Loc.T("about.title")));

        var name = new StackPanel { Spacing = 4, Padding = Ui.RowPadding };
        name.Children.Add(Ui.Text(Loc.T("app.title"), "SubtitleTextBlockStyle"));
        name.Children.Add(Ui.Text(Loc.T("about.description"), secondary: true, wrap: true));
        page.Children.Add(Ui.Card(name));

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
