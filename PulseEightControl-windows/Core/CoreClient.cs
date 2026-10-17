using System.Runtime.InteropServices;
using System.Text.Json;

namespace PulseEight.Core;

/// <summary>
/// One live instance of the shared core: holds the matrix connection and settings, publishes
/// snapshots, and runs commands. Create one per app and dispose it on exit.
/// </summary>
public sealed class CoreClient : IDisposable
{
    public const int SupportedAbi = 1;

    private readonly IntPtr _handle;
    private readonly NativeMethods.Observer _observer; // kept referenced so the native callback stays valid
    private readonly ReaderWriterLockSlim _lifetime = new();
    private bool _disposed;

    /// <summary>Raised after every change, on a background thread. Marshal to the UI thread.</summary>
    public event Action<Snapshot>? Changed;

    public CoreClient()
    {
        var abi = NativeMethods.p8_abi_version();
        if (abi != SupportedAbi)
            throw new InvalidOperationException($"pulseeight_core has interface version {abi}; this app needs {SupportedAbi}.");

        _handle = NativeMethods.p8_create();
        if (_handle == IntPtr.Zero) throw new InvalidOperationException("pulseeight_core could not start.");

        _observer = OnNativeChange;
        NativeMethods.p8_set_observer(_handle, Marshal.GetFunctionPointerForDelegate(_observer), IntPtr.Zero);
    }

    /// <summary>The state right now.</summary>
    public Snapshot Snapshot
    {
        get
        {
            _lifetime.EnterReadLock();
            try
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                return Snapshot.Parse(NativeMethods.TakeString(NativeMethods.p8_snapshot(_handle)));
            }
            finally { _lifetime.ExitReadLock(); }
        }
    }

    /// <summary>Runs one command off the calling thread and returns its result (never throws for
    /// a refused command; read <see cref="CommandResult.Error"/>).</summary>
    public Task<CommandResult> CallAsync(string command, IReadOnlyDictionary<string, object?>? fields = null)
    {
        var request = new Dictionary<string, object?> { ["cmd"] = command };
        if (fields != null) foreach (var (key, value) in fields) request[key] = value;
        var json = JsonSerializer.Serialize(request);
        return Task.Run(() =>
        {
            _lifetime.EnterReadLock();
            try
            {
                ObjectDisposedException.ThrowIf(_disposed, this);
                return CommandResult.Parse(NativeMethods.TakeString(NativeMethods.p8_call(_handle, json)));
            }
            finally { _lifetime.ExitReadLock(); }
        });
    }

    // MARK: Typed commands

    public Task<CommandResult> RouteAsync(int input, int output) =>
        CallAsync("route", new Dictionary<string, object?> { ["input"] = input, ["output"] = output });

    public Task<CommandResult> RenamePortAsync(PortSnapshot port, string name) =>
        CallAsync("renamePort", new Dictionary<string, object?> { ["mode"] = port.Mode, ["bay"] = port.Bay, ["name"] = name });

    public Task<CommandResult> SetEdidAsync(int inputBay, int profile) =>
        CallAsync("setEdid", new Dictionary<string, object?> { ["bay"] = inputBay, ["profile"] = profile });

    public Task<CommandResult> SetBacklightAsync(string level) =>
        CallAsync("setBacklight", new Dictionary<string, object?> { ["level"] = level });

    public Task<CommandResult> SetStatusLedAsync(bool on) =>
        CallAsync("setStatusLed", new Dictionary<string, object?> { ["on"] = on });

    public Task<CommandResult> RetryAsync() => CallAsync("retry");

    public Task<CommandResult> ReconnectAsync() => CallAsync("reconnect");

    /// <summary>Leave <paramref name="adminPassword"/> null or empty to keep the saved password.</summary>
    public Task<CommandResult> SaveSettingsAsync(string host, string port, string timeout, string pollInterval, string detailPollInterval, string? adminPassword) =>
        CallAsync("saveSettings", new Dictionary<string, object?>
        {
            ["host"] = host, ["port"] = port, ["timeout"] = timeout,
            ["pollInterval"] = pollInterval, ["detailPollInterval"] = detailPollInterval,
            ["adminPassword"] = adminPassword ?? "",
        });

    public Task<CommandResult> RemoveAdminPasswordAsync() => CallAsync("removeAdminPassword");

    public Task<CommandResult> SetAppearanceAsync(string value) =>
        CallAsync("setAppearance", new Dictionary<string, object?> { ["value"] = value });

    /// <summary>A language code from <see cref="Snapshot.Languages"/>, or "system".</summary>
    public Task<CommandResult> SetLanguageAsync(string code) =>
        CallAsync("setLanguage", new Dictionary<string, object?> { ["value"] = code });

    /// <summary>All user-visible text for the language in force, by dotted key. A local lookup (no
    /// network), so it is quick enough to call on the UI thread, e.g. while building a page.</summary>
    public IReadOnlyDictionary<string, string> GetStrings()
    {
        _lifetime.EnterReadLock();
        try
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            var result = CommandResult.Parse(NativeMethods.TakeString(NativeMethods.p8_call(_handle, """{"cmd":"strings"}""")));
            if (!result.Ok || result.Value == null) throw new InvalidOperationException(result.Error ?? "The core returned no strings.");
            return JsonSerializer.Deserialize<Dictionary<string, string>>(result.Value) ?? new Dictionary<string, string>();
        }
        finally { _lifetime.ExitReadLock(); }
    }

    public Task<CommandResult> SetHighlightGridAsync(bool on) =>
        CallAsync("setHighlightGrid", new Dictionary<string, object?> { ["on"] = on });

    public Task<CommandResult> SetShowStatusBarAsync(bool on) =>
        CallAsync("setShowStatusBar", new Dictionary<string, object?> { ["on"] = on });

    /// <summary>Whether the app looks for updates by itself (the updater reads this setting).</summary>
    public Task<CommandResult> SetCheckForUpdatesAsync(bool on) =>
        CallAsync("setCheckForUpdates", new Dictionary<string, object?> { ["on"] = on });

    public Task<CommandResult> ValidatePortNameAsync(string name) =>
        CallAsync("validatePortName", new Dictionary<string, object?> { ["name"] = name });

    // MARK: Native callback

    private void OnNativeChange(IntPtr context, IntPtr snapshotJson)
    {
        if (snapshotJson == IntPtr.Zero) return;
        // The pointer is valid only during this call, and must not be freed.
        var json = Marshal.PtrToStringUTF8(snapshotJson);
        if (json == null) return;
        try { Changed?.Invoke(Snapshot.Parse(json)); }
        catch (Exception) { /* a faulty subscriber must not unwind into the native caller */ }
    }

    public void Dispose()
    {
        _lifetime.EnterWriteLock();
        try
        {
            if (_disposed) return;
            _disposed = true;
            NativeMethods.p8_set_observer(_handle, IntPtr.Zero, IntPtr.Zero);
            NativeMethods.p8_destroy(_handle);
        }
        finally { _lifetime.ExitWriteLock(); }
        GC.KeepAlive(_observer);
    }
}
