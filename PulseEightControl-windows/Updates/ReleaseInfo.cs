namespace PulseEight.Updates;

/// <summary>What this build says it is. A release's version comes from its tag (scripts/release/version.py) and is stamped
/// into the assembly when it is built, so a release, a release candidate and a beta of one version report different things.
/// A development build has none and says so.</summary>
public sealed record ReleaseInfo(string Version, string Build, string Channel, string Label)
{
    public const string VersionKey = "ReleaseVersion";
    public const string BuildKey = "ReleaseBuild";
    public const string ChannelKey = "ReleaseChannel";
    public const string LabelKey = "ReleaseLabel";

    /// <summary>The feed channels that hold pre-releases. A release has none, so every app is offered it.</summary>
    public static IReadOnlyList<string> PreReleaseChannels { get; } = ["rc", "beta"];

    public static ReleaseInfo Development { get; } = new("0.0.0-dev", "0.0.0.0", "dev", "Development build");

    public bool IsDevelopment => Channel == "dev";

    /// <summary>A release candidate or a beta: what the "include pre-releases" choice follows until the person makes one.</summary>
    public bool IsPrerelease => PreReleaseChannels.Contains(Channel, StringComparer.OrdinalIgnoreCase);

    /// <summary>"0.1.0: Release Candidate 1 (build 0.1.0.201)", "0.1.0: Release (build 0.1.0.300)" or "Development build".</summary>
    public string Description
    {
        get
        {
            if (IsDevelopment) return Label;
            // The version without its -rc.1: the label says which one it is.
            var core = Version.Split('-')[0];
            return $"{core}: {Label} (build {Build})";
        }
    }

    /// <summary>Everything must be present, or this isn't a stamped build.</summary>
    public static ReleaseInfo? FromMetadata(IReadOnlyDictionary<string, string?> metadata)
    {
        string? Get(string key) => metadata.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value) ? value.Trim() : null;
        var version = Get(VersionKey);
        var build = Get(BuildKey);
        var channel = Get(ChannelKey);
        var label = Get(LabelKey);
        return version is null || build is null || channel is null || label is null
            ? null
            : new ReleaseInfo(version, build, channel.ToLowerInvariant(), label);
    }

    /// <summary>The stamp in an assembly, or <see cref="Development"/> for a build that has none.</summary>
    public static ReleaseInfo FromAssembly(System.Reflection.Assembly assembly) =>
        FromMetadata(assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
            .Cast<System.Reflection.AssemblyMetadataAttribute>()
            .GroupBy(a => a.Key)
            .ToDictionary(g => g.Key, g => g.Last().Value)) ?? Development;
}
