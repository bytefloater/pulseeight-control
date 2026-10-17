using System.Net;
using System.Text.RegularExpressions;

namespace PulseEight.Updates;

/// <summary>Turns the HTML release notes in a feed into plain text for a dialog (WinUI can't show HTML without
/// WebView2, which is a lot to take on for a few bullet points). Markup is dropped, never interpreted.</summary>
public static partial class ReleaseNotesText
{
    public static string FromHtml(string? html)
    {
        if (string.IsNullOrWhiteSpace(html)) return "";

        var text = ScriptOrStyle().Replace(html, "");
        // Whitespace between tags means nothing in HTML; only the tags decide where lines break.
        text = Whitespace().Replace(text, " ");
        text = LineBreak().Replace(text, "\n");
        text = ListItem().Replace(text, "• ");
        text = ParagraphEnd().Replace(text, "\n\n");
        text = BlockEnd().Replace(text, "\n");
        text = AnyTag().Replace(text, "");
        text = WebUtility.HtmlDecode(text);

        var lines = text.Replace("\r", "").Split('\n').Select(line => line.Trim());
        // At most one blank line in a row, none at the ends.
        var kept = new List<string>();
        foreach (var line in lines)
        {
            if (line.Length == 0 && (kept.Count == 0 || kept[^1].Length == 0)) continue;
            kept.Add(line);
        }
        while (kept.Count > 0 && kept[^1].Length == 0) kept.RemoveAt(kept.Count - 1);
        return string.Join("\n", kept);
    }

    [GeneratedRegex(@"<\s*(script|style)\b[^>]*>.*?<\s*/\s*\1\s*>", RegexOptions.IgnoreCase | RegexOptions.Singleline)]
    private static partial Regex ScriptOrStyle();

    [GeneratedRegex(@"<\s*br\s*/?\s*>", RegexOptions.IgnoreCase)]
    private static partial Regex LineBreak();

    [GeneratedRegex(@"<\s*li\b[^>]*>", RegexOptions.IgnoreCase)]
    private static partial Regex ListItem();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Whitespace();

    [GeneratedRegex(@"<\s*/\s*(p|h[1-6])\s*>", RegexOptions.IgnoreCase)]
    private static partial Regex ParagraphEnd();

    [GeneratedRegex(@"<\s*/\s*(li|div|ul|ol|tr)\s*>", RegexOptions.IgnoreCase)]
    private static partial Regex BlockEnd();

    [GeneratedRegex(@"<[^>]*>")]
    private static partial Regex AnyTag();
}
