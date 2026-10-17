using System.Text.RegularExpressions;
using PulseEight.Core;
using Xunit;

namespace PulseEight.Core.Tests;

/// <summary>The text table crossing the C interface, and the app's use of it.</summary>
[Collection("Core")]
public sealed class LocalisationTests
{
    [CoreFact]
    public void TheCoreServesItsWholeTextTable()
    {
        using var core = new CoreClient();
        var strings = core.GetStrings();

        Assert.True(strings.Count > 100);
        Assert.Equal("Settings", strings["settings.title"]);
        Assert.Equal("Connected to {0}", strings["connection.connected"]);
        Assert.All(strings, pair => Assert.False(string.IsNullOrEmpty(pair.Value), pair.Key));
    }

    [CoreFact]
    public async Task ChangingTheLanguageIsReportedAndPersisted()
    {
        using var core = new CoreClient();
        var heard = new TaskCompletionSource<Snapshot>();
        core.Changed += snapshot => { if (snapshot.Settings.Language == "en") heard.TrySetResult(snapshot); };

        var refused = await core.SetLanguageAsync("tlh");
        Assert.False(refused.Ok);

        Assert.True((await core.SetLanguageAsync("en")).Ok);
        var snapshot = await heard.Task.WaitAsync(TimeSpan.FromSeconds(10));
        Assert.Equal("en", snapshot.Language);
        Assert.Equal("English", Assert.Single(snapshot.Languages).Name);
    }

    /// <summary>Every <c>Loc.T/F/Count</c> key written in the app must exist in the core's table, so a
    /// typo shows up here and not as a raw key on screen.</summary>
    [CoreFact]
    public void EveryKeyTheAppAsksForExists()
    {
        using var core = new CoreClient();
        var strings = core.GetStrings();

        var count = new Regex(@"Loc\.Count\([^,]+,\s*""([^""]+)""\s*,\s*""([^""]+)""");
        // Keys held in arrays and then passed to Loc.T (backlight and theme choices), by their prefix.
        var literalKeys = new Regex(@"""((?:app|nav|common|connection|statusbar|port|portStatus|routing|hardware|settings|theme|language|portDialog|row|feature|detail|interval|error)\.[A-Za-z.]+)""");
        var direct = new Regex(@"Loc\.(?:T|F)\(\s*""([^""]+)""");

        var app = Path.Combine(FindAppFolder());
        var missing = new List<string>();
        var found = new HashSet<string>();
        foreach (var file in Directory.EnumerateFiles(app, "*.cs", SearchOption.AllDirectories))
        {
            if (file.Contains($"{Path.DirectorySeparatorChar}obj{Path.DirectorySeparatorChar}") ||
                file.Contains($"{Path.DirectorySeparatorChar}bin{Path.DirectorySeparatorChar}")) continue;
            var text = File.ReadAllText(file);

            var keys = new List<string>();
            keys.AddRange(direct.Matches(text).Select(m => m.Groups[1].Value));
            keys.AddRange(count.Matches(text).SelectMany(m => new[] { m.Groups[1].Value, m.Groups[2].Value }));
            keys.AddRange(literalKeys.Matches(text).Select(m => m.Groups[1].Value));

            found.UnionWith(keys);
            missing.AddRange(keys.Distinct().Where(key => !strings.ContainsKey(key)).Select(key => $"{Path.GetFileName(file)}: {key}"));
        }
        Assert.True(found.Count > 80, $"Only found {found.Count} keys in the app's source; has the scan stopped working?");
        Assert.Empty(missing);
    }

    private static string FindAppFolder()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
        {
            // The repository root holds PulseEightControl-windows/App; the Windows folder itself holds App.
            foreach (var app in new[] { Path.Combine(directory.FullName, "PulseEightControl-windows", "App"), Path.Combine(directory.FullName, "App") })
                if (File.Exists(Path.Combine(app, "Loc.cs"))) return app;
        }
        throw new DirectoryNotFoundException("Couldn't find the app's source folder above " + AppContext.BaseDirectory);
    }
}
