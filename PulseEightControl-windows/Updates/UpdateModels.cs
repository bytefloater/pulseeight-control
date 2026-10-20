using System.Runtime.InteropServices;
using NetSparkleUpdater;

namespace PulseEight.Updates;

/// <summary>Where to look for updates, who to trust, and what is installed.</summary>
public sealed record UpdateOptions(
    string FeedUrl,
    string PublicKey,
    string InstalledVersion,
    string ApplicationName,
    string StateFile,
    string? DownloadFolder = null,
    string InstallerArguments = UpdateOptions.DefaultInstallerArguments)
{
    /// <summary>Inno Setup: show progress but ask nothing, don't reboot, and close the app if it is still running.
    /// The installer's own [Run] entry starts the app again after a silent install.</summary>
    public const string DefaultInstallerArguments = "/SILENT /SUPPRESSMSGBOXES /NORESTART /CLOSEAPPLICATIONS";
}

public enum UpdateCheckStatus
{
    /// <summary>Nothing newer (or the newer version was skipped).</summary>
    UpToDate,
    Available,
    /// <summary>The feed couldn't be read or trusted; see <see cref="UpdateCheckResult.Error"/>.</summary>
    Failed,
}

/// <summary>A release the feed offers.</summary>
public sealed record UpdateOffer(
    string Version,
    string DisplayVersion,
    string? ReleaseNotesHtml,
    string? ReleaseNotesUrl,
    long SizeBytes,
    DateTimeOffset? Published,
    bool IsCritical)
{
    internal AppCastItem Item { get; init; } = new();
}

public sealed record UpdateCheckResult(UpdateCheckStatus Status, UpdateOffer? Offer = null, string? Error = null);

public readonly record struct UpdateProgress(long BytesReceived, long TotalBytes)
{
    /// <summary>0 to 100, or 0 while the total isn't known.</summary>
    public int Percent => TotalBytes > 0 ? (int) Math.Clamp(BytesReceived * 100 / TotalBytes, 0, 100) : 0;
}

/// <summary>A download or installation that failed, with a message fit to show.</summary>
public sealed class UpdateException(string message, Exception? inner = null) : Exception(message, inner);

/// <summary>One feed per processor architecture, so the right installer is offered without any custom attribute.</summary>
public static class UpdateFeeds
{
    public static string FileNameFor(Architecture architecture) => architecture switch
    {
        Architecture.X64 => "appcast-windows-x64.xml",
        Architecture.Arm64 => "appcast-windows-arm64.xml",
        _ => throw new PlatformNotSupportedException($"There is no update feed for {architecture}."),
    };

    public static string UrlFor(string baseUrl, Architecture architecture) =>
        baseUrl.TrimEnd('/') + "/" + FileNameFor(architecture);
}

/// <summary>What a build knows about where its updates come from. Stamped into the assembly at build time
/// (<c>UpdateBaseUrl</c> and <c>UpdatePublicKey</c> metadata); a development build has neither and never updates.</summary>
public sealed record UpdateConfiguration(string BaseUrl, string PublicKey)
{
    public const string BaseUrlKey = "UpdateBaseUrl";
    public const string PublicKeyKey = "UpdatePublicKey";

    /// <summary>Null unless both are present and non-blank.</summary>
    public static UpdateConfiguration? FromMetadata(IReadOnlyDictionary<string, string?> metadata)
    {
        metadata.TryGetValue(BaseUrlKey, out var url);
        metadata.TryGetValue(PublicKeyKey, out var key);
        return string.IsNullOrWhiteSpace(url) || string.IsNullOrWhiteSpace(key)
            ? null
            : new UpdateConfiguration(url.Trim(), key.Trim());
    }

    public static UpdateConfiguration? FromAssembly(System.Reflection.Assembly assembly) =>
        FromMetadata(assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
            .Cast<System.Reflection.AssemblyMetadataAttribute>()
            .GroupBy(a => a.Key)
            .ToDictionary(g => g.Key, g => g.Last().Value));
}

/// <summary>What the UI needs from an updater (and what tests of the UI can fake).</summary>
public interface IUpdateService : IDisposable
{
    /// <summary>Raised when the installer is about to run and the app must close itself.</summary>
    event Action? ExitRequested;

    /// <summary>Whether release candidates and betas are offered as well as releases. Read at every check, so changing it
    /// takes effect at the next one. Off (the default) offers only releases.</summary>
    bool IncludePrereleases { get; set; }

    Task<UpdateCheckResult> CheckAsync(CancellationToken cancellation = default);

    /// <summary>Downloads and verifies the update. Throws <see cref="UpdateException"/> if that fails.</summary>
    Task DownloadAsync(UpdateOffer offer, IProgress<UpdateProgress>? progress = null, CancellationToken cancellation = default);

    /// <summary>Runs the downloaded installer; <see cref="ExitRequested"/> follows.</summary>
    Task InstallAsync(UpdateOffer offer);

    /// <summary>Stops offering this version (a newer one is still offered).</summary>
    void Skip(UpdateOffer offer);
}
