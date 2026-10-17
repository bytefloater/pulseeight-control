namespace PulseEightControl;

/// <summary>
/// User-visible text, looked up by dotted key (<c>Loc.T("settings.title")</c>). The text itself lives
/// once, in the shared core (PulseEightKit, <c>StringKey</c> and the catalogs); the window loads the
/// table for the language in force at start-up and again whenever the language changes.
/// A key the table doesn't have shows as the key itself, which is easy to spot.
/// </summary>
internal static class Loc
{
    private static IReadOnlyDictionary<string, string> _table = new Dictionary<string, string>();

    /// <summary>Code of the language the loaded table is for ("en"); empty before the first load.</summary>
    public static string Current { get; private set; } = "";

    public static void Load(IReadOnlyDictionary<string, string> table, string language)
    {
        _table = table;
        Current = language;
    }

    public static string T(string key) => _table.TryGetValue(key, out var text) ? text : key;

    /// <summary>The text for a key with <c>{0}</c>, <c>{1}</c>... replaced by the arguments.</summary>
    public static string F(string key, params object?[] arguments)
    {
        var text = T(key);
        for (var i = 0; i < arguments.Length; i++)
            text = text.Replace("{" + i + "}", arguments[i]?.ToString() ?? "");
        return text;
    }

    /// <summary><paramref name="one"/> for a count of 1, otherwise <paramref name="other"/> (given the count as <c>{0}</c>).</summary>
    public static string Count(int count, string one, string other) => count == 1 ? T(one) : F(other, count);
}
