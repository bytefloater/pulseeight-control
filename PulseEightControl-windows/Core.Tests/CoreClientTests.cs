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
            Skip = "Set P8_CORE_LIBRARY to the built pulseeight_core library (see windows/README.md)";
    }
}

/// <summary>Runs tools/fake_matrix.py for the duration of the tests and gives the core a scratch
/// settings folder, so nothing touches the real configuration.</summary>
public sealed class FakeMatrixFixture : IDisposable
{
    public const int Port = 8091;
    public const string Password = "secret";

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

        var script = Path.Combine(FindRepositoryRoot(), "tools", "fake_matrix.py");
        var python = RuntimeInformation.IsOSPlatform(OSPlatform.Windows) ? "python" : "python3";
        _fake = Process.Start(new ProcessStartInfo(python, $"\"{script}\" --port {Port} --password {Password} --quiet")
        {
            RedirectStandardOutput = true,
            UseShellExecute = false,
        }) ?? throw new InvalidOperationException("Couldn't start the fake matrix");
        _fake.StandardOutput.ReadLine(); // its "listening" line
    }

    private static string FindRepositoryRoot()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory != null; directory = directory.Parent)
            if (File.Exists(Path.Combine(directory.FullName, "tools", "fake_matrix.py"))) return directory.FullName;
        throw new DirectoryNotFoundException("Couldn't find tools/fake_matrix.py above " + AppContext.BaseDirectory);
    }

    public void Dispose()
    {
        if (_fake is { HasExited: false }) { _fake.Kill(); _fake.WaitForExit(); }
    }
}

public sealed class CoreClientTests : IClassFixture<FakeMatrixFixture>
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

        var saved = await core.SaveSettingsAsync("127.0.0.1", FakeMatrixFixture.Port.ToString(), "3", "2", "5", FakeMatrixFixture.Password);
        Assert.True(saved.Ok, saved.Error);

        var connected = await WaitFor(core, s => s.IsConnected && s.Outputs.Any(o => o.Details.Count > 0), "connection and port details");
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

    [CoreFact]
    public void RefusesUseAfterDispose()
    {
        var core = new CoreClient();
        core.Dispose();
        Assert.Throws<ObjectDisposedException>(() => core.Snapshot);
        core.Dispose(); // idempotent
    }
}
