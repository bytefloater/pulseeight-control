using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using PulseEight.Updates;

namespace PulseEightControl.Updates;

/// <summary>
/// Decides when to look for updates and what to show: a quiet check shortly after start and then about once
/// a day (when the setting is on), and a "Check now" that always says what it found. Offers go to
/// <see cref="UpdateDialog"/>. A development build has no feed or key compiled in, so it never checks.
/// </summary>
internal sealed class UpdateController : IDisposable
{
    private static readonly TimeSpan FirstCheckDelay = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan CheckInterval = TimeSpan.FromHours(24);

    private readonly IUpdateService? _service;
    private readonly DispatcherQueue _queue;
    private readonly Func<bool> _automaticChecksOn;
    private DispatcherQueueTimer? _timer;
    private string? _laterVersion;
    private bool _offering;

    /// <summary>What this build is, as the feed compares it ("0.1.0.42").</summary>
    public string InstalledVersion { get; }

    /// <summary>False for builds without a feed and key; the settings page says so.</summary>
    public bool IsAvailable => _service != null;

    public bool Busy { get; private set; }

    public DateTimeOffset? LastChecked { get; private set; }

    /// <summary>Raised on the UI thread when <see cref="Busy"/> or <see cref="LastChecked"/> changed.</summary>
    public event Action? Changed;

    public UpdateController(DispatcherQueue queue, Func<bool> automaticChecksOn)
    {
        _queue = queue;
        _automaticChecksOn = automaticChecksOn;

        var assembly = typeof(UpdateController).Assembly;
        InstalledVersion = (assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
                            ?? assembly.GetName().Version?.ToString() ?? "0.0.0").Split('+')[0];

        try
        {
            if (UpdateConfiguration.FromAssembly(assembly) is { } configuration)
            {
                var folder = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PulseEightControl");
                _service = new UpdateService(new UpdateOptions(
                    UpdateFeeds.UrlFor(configuration.BaseUrl, RuntimeInformation.ProcessArchitecture),
                    configuration.PublicKey,
                    InstalledVersion,
                    "PulseEight Control",
                    System.IO.Path.Combine(folder, "updates.json"),
                    System.IO.Path.Combine(folder, "updates")));
                _service.ExitRequested += () => _queue.TryEnqueue(() => Application.Current.Exit());
            }
        }
        catch (Exception exception)
        {
            // An unsupported processor, or a feed address that isn't one: run without updates rather than not at all.
            CrashLog.Write(exception);
            _service = null;
        }
    }

    /// <summary>Starts the quiet checks. Call once the window can show a dialog.</summary>
    public void StartAutomaticChecks()
    {
        if (_service == null || _timer != null) return;
        _timer = _queue.CreateTimer();
        _timer.Interval = FirstCheckDelay;
        _timer.IsRepeating = true;
        _timer.Tick += async (timer, _) =>
        {
            timer.Interval = CheckInterval;
            if (_automaticChecksOn()) await CheckAsync(userInitiated: false);
        };
        _timer.Start();
    }

    /// <summary>"Check for updates": offers an update, or says there isn't one, or says why it couldn't tell.</summary>
    public Task CheckNowAsync() => CheckAsync(userInitiated: true);

    private async Task CheckAsync(bool userInitiated)
    {
        if (_service == null || Busy) return;
        SetBusy(true);
        try
        {
            var result = await _service.CheckAsync();
            LastChecked = DateTimeOffset.Now;
            SetBusy(false);

            switch (result.Status)
            {
                case UpdateCheckStatus.Available when result.Offer is { } offer:
                    // A quiet check doesn't ask again about a version that was put off until the next start.
                    if (!userInitiated && offer.Version == _laterVersion) return;
                    if (_offering) return;
                    _offering = true;
                    try
                    {
                        var decision = await UpdateDialog.ShowAsync(_service, offer, InstalledVersion);
                        if (decision == UpdateDecision.Later) _laterVersion = offer.Version;
                    }
                    finally { _offering = false; }
                    break;
                case UpdateCheckStatus.Failed when userInitiated:
                    await Dialogs.ErrorAsync(Loc.T("settings.updates"), Loc.F("update.checkFailed", result.Error ?? Loc.T("common.unknownError")));
                    break;
                case UpdateCheckStatus.UpToDate when userInitiated:
                    await Dialogs.ErrorAsync(Loc.T("settings.updates"), Loc.F("update.upToDate", InstalledVersion));
                    break;
            }
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            if (userInitiated) await Dialogs.ErrorAsync(Loc.T("settings.updates"), Loc.F("update.checkFailed", exception.Message));
        }
        finally
        {
            if (Busy) SetBusy(false);
        }
    }

    private void SetBusy(bool busy)
    {
        Busy = busy;
        Changed?.Invoke();
    }

    public void Dispose()
    {
        _timer?.Stop();
        _service?.Dispose();
    }
}
