using System.Text;
using NetSparkleUpdater;
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
            _downloadedPath = await task.Task.ConfigureAwait(false);
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
        if (path == null || !File.Exists(path)) throw new UpdateException("The update hasn't been downloaded.");
        await _sparkle.InstallUpdate(offer.Item, path).ConfigureAwait(false);
    }

    public void Skip(UpdateOffer offer) => _sparkle.Configuration.SetVersionToSkip(offer.Version);

    public void Dispose() => _sparkle.Dispose();

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
