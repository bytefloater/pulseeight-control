using System.Text;
using NetSparkleUpdater;
using NetSparkleUpdater.AppCastHandlers;
using NetSparkleUpdater.Configurations;
using NetSparkleUpdater.Enums;
using NetSparkleUpdater.Interfaces;
using NetSparkleUpdater.SignatureVerifiers;

namespace PulseEight.Updates;

/// <summary>
/// The updater, over NetSparkle's core (no UI package): a feed that is signed, downloads that are signed,
/// and an installer that runs when the user says so.
///
/// Strict security: the feed must carry a signature file beside it (<c>appcast.xml.signature</c>) and every
/// download must match the signature in the feed, both made with the key the app was built with. An
/// unsigned or tampered feed or file is refused, not offered with a warning.
/// </summary>
public sealed class UpdateService : IUpdateService
{
    private readonly SparkleUpdater _sparkle;
    private readonly RecordingLogger _log = new();
    private readonly object _gate = new();
    private TaskCompletionSource<string>? _download;
    private IProgress<UpdateProgress>? _progress;
    private string? _downloadedPath;

    public event Action? ExitRequested;

    /// <summary>Where the verified installer is, once downloaded.</summary>
    public string? DownloadedPath => _downloadedPath;

    /// <inheritdoc />
    public bool IncludePrereleases { get; set; }

    public UpdateService(UpdateOptions options)
    {
        var accessor = new FixedAssemblyAccessor(options.ApplicationName, options.InstalledVersion);
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(options.StateFile))!);

        _sparkle = new SparkleUpdater(options.FeedUrl, new Ed25519Checker(SecurityMode.Strict, options.PublicKey))
        {
            // No NetSparkle window ever appears: the app draws its own.
            UIFactory = null,
            Configuration = new JSONConfiguration(accessor, options.StateFile),
            LogWriter = _log,
            CustomInstallerArguments = options.InstallerArguments,
            // The installer starts the app again (a [Run] entry for silent installs), so NetSparkle mustn't.
            RelaunchAfterUpdate = false,
        };
        // Our own filter rather than NetSparkle's ChannelAppCastFilter, whose behaviour with no channels listed isn't spelled out:
        // this one does exactly what the feeds are built for (see PrereleaseChannelFilter).
        _sparkle.AppCastHelper.AppCastFilter = new PrereleaseChannelFilter(() => IncludePrereleases);
        if (options.DownloadFolder is { Length: > 0 } folder)
        {
            Directory.CreateDirectory(folder);
            _sparkle.TmpDownloadFilePath = folder;
        }

        _sparkle.DownloadMadeProgress += (_, _, args) => _progress?.Report(new UpdateProgress(args.BytesReceived, args.TotalBytesToReceive));
        _sparkle.DownloadFinished += (_, path) => Complete(task => task.TrySetResult(path));
        _sparkle.DownloadCanceled += (_, _) => Complete(task => task.TrySetCanceled());
        _sparkle.DownloadHadError += (_, _, error) =>
            Complete(task => task.TrySetException(new UpdateException(error.Message, error)));
        _sparkle.DownloadedFileIsCorrupt += (_, _) =>
            Complete(task => task.TrySetException(new UpdateException("The downloaded update failed its signature check, so it was discarded.")));
        _sparkle.DownloadedFileThrewWhileCheckingSignature += (_, _) =>
            Complete(task => task.TrySetException(new UpdateException("The downloaded update couldn't be checked, so it was discarded.")));
        _sparkle.CloseApplicationAsync += () =>
        {
            ExitRequested?.Invoke();
            return Task.CompletedTask;
        };
    }

    private void Complete(Action<TaskCompletionSource<string>> finish)
    {
        TaskCompletionSource<string>? task;
        lock (_gate) task = _download;
        if (task != null) finish(task);
    }

    public async Task<UpdateCheckResult> CheckAsync(CancellationToken cancellation = default)
    {
        try
        {
            _log.Clear();
            var info = await _sparkle.CheckForUpdatesQuietly(false).WaitAsync(cancellation).ConfigureAwait(false);
            switch (info.Status)
            {
                case UpdateStatus.UpdateAvailable when info.Updates is { Count: > 0 }:
                    var newest = info.Updates.OrderByDescending(item => item.SemVerLikeVersion).First();
                    return new UpdateCheckResult(UpdateCheckStatus.Available, ToOffer(newest));
                case UpdateStatus.UpdateNotAvailable:
                case UpdateStatus.UserSkipped:
                    return new UpdateCheckResult(UpdateCheckStatus.UpToDate);
                default:
                    return new UpdateCheckResult(UpdateCheckStatus.Failed, Error: _log.Reason("The update feed couldn't be read or didn't pass its signature check."));
            }
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception exception)
        {
            return new UpdateCheckResult(UpdateCheckStatus.Failed, Error: exception.Message);
        }
    }

    public async Task DownloadAsync(UpdateOffer offer, IProgress<UpdateProgress>? progress = null, CancellationToken cancellation = default)
    {
        var task = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        lock (_gate)
        {
            _download = task;
            _progress = progress;
        }
        try
        {
            using var registration = cancellation.Register(() => _sparkle.CancelFileDownload());
            await _sparkle.InitAndBeginDownload(offer.Item).ConfigureAwait(false);
            _downloadedPath = InstallerNamed(await task.Task.ConfigureAwait(false), offer);
        }
        finally
        {
            lock (_gate)
            {
                _download = null;
                _progress = null;
            }
        }
    }

    public async Task InstallAsync(UpdateOffer offer)
    {
        var path = _downloadedPath ?? await _sparkle.GetDownloadPathForAppCastItem(offer.Item).ConfigureAwait(false);
        if (path != null && File.Exists(path)) path = InstallerNamed(path, offer);
        if (path == null || !File.Exists(path)) throw new UpdateException("The update hasn't been downloaded.");
        await _sparkle.InstallUpdate(offer.Item, path).ConfigureAwait(false);
    }

    public void Skip(UpdateOffer offer) => _sparkle.Configuration.SetVersionToSkip(offer.Version);

    public void Dispose() => _sparkle.Dispose();

    /// <summary>
    /// Gives the downloaded installer the file name the feed's address ends in ("...-Setup-0.2.0-x64.exe"), and returns where it is.
    /// GitHub answers a release download with a redirect to an asset whose own name is a bare id, and NetSparkle names the
    /// file from where it ended up: no extension at all. NetSparkle decides how to run a file by its extension, so without
    /// ".exe" the update is "installed" by running nothing, the app closes, and the old version starts again.
    /// </summary>
    private static string InstallerNamed(string path, UpdateOffer offer)
    {
        var wanted = WantedFileName(offer);
        if (wanted == null || string.Equals(Path.GetFileName(path), wanted, StringComparison.OrdinalIgnoreCase)) return path;

        var target = Path.Combine(Path.GetDirectoryName(path)!, wanted);
        File.Move(path, target, overwrite: true);
        return target;
    }

    /// <summary>The last part of the feed's download address if it is a runnable installer, else a name made from the version.</summary>
    private static string? WantedFileName(UpdateOffer offer)
    {
        string? name = null;
        if (Uri.TryCreate(offer.Item.DownloadLink, UriKind.Absolute, out var link))
            name = Uri.UnescapeDataString(Path.GetFileName(link.LocalPath));
        if (!string.IsNullOrEmpty(name) && name.IndexOfAny(Path.GetInvalidFileNameChars()) < 0 &&
            RunnableExtensions.Contains(Path.GetExtension(name), StringComparer.OrdinalIgnoreCase))
            return name;
        return null;
    }

    private static readonly string[] RunnableExtensions = [".exe", ".msi", ".msix"];

    private static UpdateOffer ToOffer(AppCastItem item) => new(
        item.Version ?? string.Empty,
        string.IsNullOrWhiteSpace(item.ShortVersion) ? item.Version ?? string.Empty : item.ShortVersion,
        string.IsNullOrWhiteSpace(item.Description) ? null : item.Description,
        string.IsNullOrWhiteSpace(item.ReleaseNotesLink) ? null : item.ReleaseNotesLink,
        item.UpdateSize,
        item.PublicationDate == default ? null : new DateTimeOffset(item.PublicationDate),
        item.IsCriticalUpdate)
    {
        Item = item,
    };

    /// <summary>NetSparkle reports why a check failed only through its log; this keeps the last lines to show.</summary>
    private sealed class RecordingLogger : ILogger
    {
        private readonly StringBuilder _text = new();

        public void Initialize() { }

        public void Initialize(string tag, string path, bool shouldLogToFile) { }

        public void PrintMessage(string message, params object[]? arguments)
        {
            string line;
            try { line = arguments is { Length: > 0 } ? string.Format(message, arguments) : message; }
            catch (FormatException) { line = message; }
            lock (_text) _text.AppendLine(line);
        }

        public void Clear() { lock (_text) _text.Clear(); }

        public string Reason(string fallback)
        {
            lock (_text)
            {
                var lines = _text.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
                return lines.Length == 0 ? fallback : $"{fallback} ({lines[^1]})";
            }
        }
    }
}

/// <summary>NetSparkle wants an object that says what is installed; here it is simply told.</summary>
internal sealed class FixedAssemblyAccessor(string applicationName, string version) : IAssemblyAccessor
{
    public string AssemblyCompany => applicationName;
    public string AssemblyCopyright => string.Empty;
    public string AssemblyDescription => applicationName;
    public string AssemblyTitle => applicationName;
    public string AssemblyProduct => applicationName;
    public string AssemblyVersion => version;
}

/// <summary>Which feed items may be offered. An item with no channel (a release) is always eligible. An item on a channel (a
/// release candidate, <c>rc</c>, or a beta, <c>beta</c>) is eligible only when pre-releases are on. Anything not newer than
/// what is installed is dropped (NetSparkle skips its own check for that when a filter is set).</summary>
internal sealed class PrereleaseChannelFilter(Func<bool> includePrereleases) : IAppCastFilter
{
    public IEnumerable<AppCastItem> GetFilteredAppCastItems(SemVerLike installed, IEnumerable<AppCastItem> items) =>
        items.Where(item => Allowed(item) && item.SemVerLikeVersion.CompareTo(installed) > 0);

    private bool Allowed(AppCastItem item)
    {
        if (string.IsNullOrWhiteSpace(item.Channel)) return true;
        return includePrereleases() && ReleaseInfo.PreReleaseChannels.Contains(item.Channel.Trim(), StringComparer.OrdinalIgnoreCase);
    }
}
