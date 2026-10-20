using System.Diagnostics;
using System.Runtime.InteropServices;
using PulseEight.Core;
using Xunit;

namespace PulseEight.Core.Tests;

/// <summary>Skipped unless P8_CORE_LIBRARY names a built pulseeight_core library.</summary>
public sealed class CoreFactAttribute : FactAttribute
{
    public CoreFactAttribute()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("P8_CORE_LIBRARY")))
            Skip = "Set P8_CORE_LIBRARY to the built pulseeight_core library (see PulseEightControl-windows/README.md)";
    }
}

/// <summary>Runs the Swift fake matrix (p8fake) for the duration of the tests and gives the core a scratch
/// settings folder, so nothing touches the real configuration.</summary>
public sealed class FakeMatrixFixture : IDisposable
{
    public const string Password = "secret";

    /// <summary>The port p8fake picked (it is started on port 0, so tests never collide with a fake you
    /// are running yourself, or with another test run on the same machine).</summary>
    public int Port { get; private set; }

    private readonly Process? _fake;

    [DllImport("libc", EntryPoint = "setenv")]
    private static extern int UnixSetEnv(string name, string value, int overwrite);

    private static void SetNativeEnvironment(string name, string value)
    {
        Environment.SetEnvironmentVariable(name, value);
        // .NET's copy of the environment is not what native code (getenv) sees on Unix.
        if (!RuntimeInformation.IsOSPlatform(OSPlatform.Windows)) UnixSetEnv(name, value, 1);
    }

    public FakeMatrixFixture()
    {
        if (string.IsNullOrEmpty(Environment.GetEnvironmentVariable("P8_CORE_LIBRARY"))) return;

        var scratch = Path.Combine(Path.GetTempPath(), "p8core-net-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(scratch);
        SetNativeEnvironment("P8_CONFIG_DIR", scratch);
        SetNativeEnvironment("P8_SECRET_STORE", "file");

        _fake = Process.Start(new ProcessStartInfo(FindFakeServer(), $"--port 0 --password {Password} --quiet")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        }) ?? throw new InvalidOperationException("Couldn't start the fake matrix");
        // Its "Fake NeoMatrix on http://127.0.0.1:<port> ..." line.
        var line = _fake.StandardOutput.ReadLine() ?? throw new InvalidOperationException("p8fake printed nothing");
        var match = System.Text.RegularExpressions.Regex.Match(line, @"http://[^:]+:(\d+)");
        if (!match.Success) throw new InvalidOperationException($"Couldn't read the port from p8fake's output: {line}");
        Port = int.Parse(match.Groups[1].Value);
    }

    /// <summary>P8_FAKE_SERVER names the p8fake executable; otherwise the debug build under
    /// out/fake (or PulseEightFakeServer/.build) is used; see the README.</summary>
    private static string FindFakeServer()
    {
        var explicitPath = Environment.GetEnvironmentVariable("P8_FAKE_SERVER");
        if (!string.IsNullOrEmpty(explicitPath)) return explicitPath;

        var name = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "p8fake.exe" : "p8fake";
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
        {
            if (!Directory.Exists(Path.Combine(directory.FullName, "PulseEightFakeServer"))) continue;
            // The repository root. Build folders in order of preference: out/fake (a build with
            // --scratch-path out/fake) and the package's own .build.
            foreach (var build in new[] { Path.Combine(directory.FullName, "out", "fake"), Path.Combine(directory.FullName, "PulseEightFakeServer", ".build") })
            {
                if (!Directory.Exists(build)) continue;
                // <build>/debug on current SwiftPM, <build>/<triple>/debug on older ones.
                var direct = Path.Combine(build, "debug", name);
                if (File.Exists(direct)) return direct;
                foreach (var triple in Directory.GetDirectories(build))
                {
                    var candidate = Path.Combine(triple, "debug", name);
                    if (File.Exists(candidate)) return candidate;
                }
            }
        }
        throw new FileNotFoundException(
            "Couldn't find the p8fake executable. Run `swift build --package-path PulseEightFakeServer --scratch-path out/fake`, or set P8_FAKE_SERVER.");
    }

    public void Dispose()
    {
        if (_fake is { HasExited: false }) { _fake.Kill(); _fake.WaitForExit(); }
    }
}

/// <summary>One fake matrix and one scratch config for every test that uses the core: they share a
/// port and the native library reads its settings from an environment variable, so these tests
/// must not run in parallel.</summary>
[CollectionDefinition("Core")]
public sealed class CoreCollection : ICollectionFixture<FakeMatrixFixture>;

[Collection("Core")]
public sealed class CoreClientTests(FakeMatrixFixture fake)
{
    private static async Task<Snapshot> WaitFor(CoreClient core, Func<Snapshot, bool> condition, string what)
    {
        var deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline)
        {
            var snapshot = core.Snapshot;
            if (condition(snapshot)) return snapshot;
            await Task.Delay(100);
        }
        throw new Exception($"Timed out waiting for {what}; phase is {core.Snapshot.Phase}");
    }

    [CoreFact]
    public async Task ConnectsRoutesRenamesAndReportsChanges()
    {
        using var core = new CoreClient();
        var phases = new List<string>();
        core.Changed += snapshot => { lock (phases) phases.Add(snapshot.Phase); };

        Assert.Equal(Snapshot.SupportedSchema, core.Snapshot.Schema);

        var rejected = await core.SaveSettingsAsync("", "80", "3", "2", "5", null);
        Assert.False(rejected.Ok);
        Assert.False(string.IsNullOrWhiteSpace(rejected.Error));

        var saved = await core.SaveSettingsAsync("127.0.0.1", fake.Port.ToString(), "3", "2", "5", FakeMatrixFixture.Password);
        Assert.True(saved.Ok, saved.Error);

        var connected = await WaitFor(core, s => s.IsConnected && s.Outputs.Any(o => o.Details.Count > 0) && s.SystemRows.Count > 0, "connection, port details and system details");
        Assert.Equal(8, connected.Inputs.Count);
        Assert.Equal(8, connected.Outputs.Count);
        Assert.True(connected.AdminConfigured);
        Assert.Equal("Sky", connected.Outputs[0].SourceName);
        Assert.NotEmpty(connected.SystemRows);
        Assert.NotEmpty(connected.EdidProfiles);

        Assert.True((await core.RouteAsync(4, 0)).Ok);
        await WaitFor(core, s => s.Outputs[0].ReceiveFrom == 4, "route to show");

        Assert.True((await core.RenamePortAsync(core.Snapshot.Inputs[0], "Cable Box")).Ok);
        await WaitFor(core, s => s.Inputs[0].Name == "Cable Box", "rename to show");

        var tooLong = await core.RenamePortAsync(core.Snapshot.Inputs[0], "This name is far too long");
        Assert.False(tooLong.Ok);
        Assert.Contains("13", tooLong.Error);

        Assert.Equal("Hi", (await core.ValidatePortNameAsync("  Hi  ")).Value);

        Assert.True((await core.SetBacklightAsync("off")).Ok);
        await WaitFor(core, s => s.FrontPanel?.Backlight == "off", "backlight to show");

        Assert.True((await core.SetHighlightGridAsync(false)).Ok);
        Assert.False(core.Snapshot.Settings.HighlightGrid);

        Assert.False((await core.CallAsync("nonsense")).Ok);

        Assert.True((await core.RemoveAdminPasswordAsync()).Ok);
        await WaitFor(core, s => !s.AdminConfigured, "admin password removal");

        lock (phases) Assert.Contains("connected", phases);
    }

    /// <summary>The contract: <c>Changed</c> is raised on a background thread, so a UI must marshal it.</summary>
    [CoreFact]
    public async Task ChangedIsRaisedOffTheCallersThread()
    {
        using var core = new CoreClient();
        var callerThread = Environment.CurrentManagedThreadId;
        var threads = new List<int>();
        core.Changed += _ => { lock (threads) threads.Add(Environment.CurrentManagedThreadId); };

        Assert.True((await core.SetAppearanceAsync("dark")).Ok);
        Assert.True((await core.SetAppearanceAsync("light")).Ok);
        await Task.Delay(300);

        lock (threads)
        {
            Assert.NotEmpty(threads);
            Assert.DoesNotContain(callerThread, threads);
        }
    }

    /// <summary>"May be called from any thread": a burst of simultaneous commands and reads must all succeed.</summary>
    [CoreFact]
    public async Task ManyConcurrentCallsAndSnapshotsAllSucceed()
    {
        using var core = new CoreClient();

        var calls = Enumerable.Range(0, 100).Select(i => i % 2 == 0
            ? core.ValidatePortNameAsync($"Port {i}")
            : core.SetHighlightGridAsync(i % 4 == 1)).ToArray();
        var reads = Enumerable.Range(0, 100).Select(_ => Task.Run(() => core.Snapshot.Schema)).ToArray();

        var results = await Task.WhenAll(calls);
        var schemas = await Task.WhenAll(reads);

        Assert.All(results, result => Assert.True(result.Ok, result.Error));
        Assert.All(schemas, schema => Assert.Equal(Snapshot.SupportedSchema, schema));
    }

    /// <summary>Disposing while commands are still running must neither crash nor hang: each call either
    /// finishes or is refused with ObjectDisposedException.</summary>
    [CoreFact]
    public async Task DisposingWhileCallsAreInFlightIsClean()
    {
        var core = new CoreClient();
        var pending = Enumerable.Range(0, 30).Select(_ => core.RetryAsync()).ToArray();
        core.Dispose();

        foreach (var call in pending)
        {
            try { await call; }
            catch (ObjectDisposedException) { /* started after Dispose: refused, as documented */ }
        }
        Assert.Throws<ObjectDisposedException>(() => core.Snapshot);
    }

    [CoreFact]
    public async Task SettingsSurviveARestartOfTheCore()
    {
        using (var first = new CoreClient())
        {
            Assert.True((await first.SaveSettingsAsync("192.0.2.77", "8123", "4", "3", "9", null)).Ok);
            Assert.True((await first.SetLanguageAsync("en")).Ok);
        }

        using var second = new CoreClient();
        var settings = second.Snapshot.Settings;
        Assert.Equal("192.0.2.77", settings.Host);
        Assert.Equal(8123, settings.Port);
        Assert.Equal("en", settings.Language);

        // Leave the shared scratch settings pointing at the fake for any test that runs after this one.
        Assert.True((await second.SaveSettingsAsync("127.0.0.1", fake.Port.ToString(), "3", "2", "5", FakeMatrixFixture.Password)).Ok);
    }

    [CoreFact]
    public async Task TheUpdateCheckSettingCanBeTurnedOffAndStaysOff()
    {
        using (var first = new CoreClient())
        {
            Assert.True(first.Snapshot.Settings.CheckForUpdates, "on by default");
            Assert.True((await first.SetCheckForUpdatesAsync(false)).Ok);
            Assert.False(first.Snapshot.Settings.CheckForUpdates);
        }

        using var second = new CoreClient();
        Assert.False(second.Snapshot.Settings.CheckForUpdates, "remembered across a restart");
        Assert.True((await second.SetCheckForUpdatesAsync(true)).Ok);
    }

    [CoreFact]
    public async Task ThePreReleaseChoiceStartsUnsetCanBeSetAndClearedAndIsRemembered()
    {
        using (var first = new CoreClient())
        {
            Assert.Null(first.Snapshot.Settings.UpdatePrereleases);
            Assert.True((await first.SetUpdatePrereleasesAsync(true)).Ok);
            Assert.True(first.Snapshot.Settings.UpdatePrereleases);
            Assert.True((await first.SetUpdatePrereleasesAsync(false)).Ok);
            Assert.False(first.Snapshot.Settings.UpdatePrereleases);
        }

        using var second = new CoreClient();
        Assert.False(second.Snapshot.Settings.UpdatePrereleases);
        Assert.True((await second.SetUpdatePrereleasesAsync(null)).Ok);
        Assert.Null(second.Snapshot.Settings.UpdatePrereleases);
    }

    [CoreFact]
    public async Task MalformedFieldsAreRefusedNotFatal()
    {
        using var core = new CoreClient();

        Assert.False((await core.CallAsync("route", new Dictionary<string, object?> { ["input"] = "zero", ["output"] = 1 })).Ok);
        Assert.False((await core.CallAsync("route", new Dictionary<string, object?> { ["input"] = null, ["output"] = null })).Ok);
        Assert.False((await core.CallAsync("setBacklight", new Dictionary<string, object?> { ["level"] = "blinding" })).Ok);
        Assert.False((await core.CallAsync("renamePort", new Dictionary<string, object?> { ["mode"] = "Sideways", ["bay"] = 0, ["name"] = "x" })).Ok);
        Assert.False((await core.CallAsync("saveSettings", new Dictionary<string, object?> { ["host"] = "h", ["port"] = new[] { 1, 2 } })).Ok);
        Assert.False((await core.CallAsync("")).Ok);

        // Still working afterwards.
        Assert.True((await core.ValidatePortNameAsync("Fine")).Ok);
    }

    [CoreFact]
    public void RefusesUseAfterDispose()
    {
        var core = new CoreClient();
        core.Dispose();
        Assert.Throws<ObjectDisposedException>(() => core.Snapshot);
        core.Dispose(); // idempotent
    }
}
