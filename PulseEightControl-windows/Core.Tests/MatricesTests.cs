using PulseEight.Core;
using Xunit;

namespace PulseEight.Core.Tests;

/// <summary>Several matrices, and the health report, through the real library and the fake matrix.</summary>
[Collection("Core")]
public sealed class MatricesTests(FakeMatrixFixture fake)
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
    public async Task MatricesCanBeAddedSelectedChangedAndRemoved()
    {
        using var core = new CoreClient();
        // Whatever earlier tests left, make sure the selected matrix is the fake.
        Assert.True((await core.SaveSettingsAsync("127.0.0.1", fake.Port.ToString(), "3", "2", "5", FakeMatrixFixture.Password)).Ok);
        var before = core.Snapshot;
        var first = Assert.Single(before.Matrices, m => m.Selected);
        Assert.Equal(first.Id, before.SelectedMatrix?.Id);
        Assert.True(first.AdminPasswordSaved);

        var refused = await core.SaveMatrixAsync(null, "Nowhere", "", "80", "3", "2", "5", null);
        Assert.False(refused.Ok);
        Assert.Equal(before.Matrices.Count, core.Snapshot.Matrices.Count);

        var added = await core.SaveMatrixAsync(null, "Cinema", "192.0.2.10", "8080", "3", "2", "5", "hunter2");
        Assert.True(added.Ok, added.Error);
        var id = added.Value!;
        var cinema = Assert.Single(core.Snapshot.Matrices, m => m.Id == id);
        Assert.Equal("Cinema", cinema.DisplayName);
        Assert.Equal("192.0.2.10:8080", cinema.Address);
        Assert.True(cinema.AdminPasswordSaved);
        Assert.False(cinema.Selected, "a matrix added later is not shown until picked");

        Assert.True((await core.SaveMatrixAsync(id, "", "192.0.2.10", "80", "3", "2", "5", null, clearAdminPassword: true)).Ok);
        var renamed = Assert.Single(core.Snapshot.Matrices, m => m.Id == id);
        Assert.Equal("192.0.2.10", renamed.DisplayName); // no name: the address is shown
        Assert.False(renamed.AdminPasswordSaved);

        Assert.True((await core.SelectMatrixAsync(id)).Ok);
        Assert.Equal(id, core.Snapshot.SelectedMatrix?.Id);
        Assert.False((await core.SelectMatrixAsync("00000000-0000-0000-0000-000000000000")).Ok);

        Assert.True((await core.RemoveMatrixAsync(id)).Ok);
        Assert.DoesNotContain(core.Snapshot.Matrices, m => m.Id == id);
        Assert.NotNull(core.Snapshot.SelectedMatrix); // another one is shown instead
    }

    [CoreFact]
    public async Task TheHealthReportAndSystemDetailsArrive()
    {
        using var core = new CoreClient();
        Assert.True((await core.SaveSettingsAsync("127.0.0.1", fake.Port.ToString(), "3", "2", "5", FakeMatrixFixture.Password)).Ok);

        var snapshot = await WaitFor(core, s => s.IsConnected && s.HealthRows.Count > 0 && s.SystemRows.Count > 0, "health and system details");
        Assert.Null(snapshot.SystemError);
        Assert.All(snapshot.HealthRows, row => Assert.False(string.IsNullOrEmpty(row.Label)));
        Assert.All(snapshot.HealthRows, row => Assert.Contains(row.Group, new[] { "health", "diagnostics" }));
        Assert.Contains(snapshot.HealthRows, row => row.Group == "health" && row.Ok != null);

        // The cloud link (/Monitoring/Settings) arrives with the health report, at the end of the health group.
        var cloud = await WaitFor(core, s => s.HealthRows.Any(r => r.Label == "Cloud connection"), "the cloud link");
        var link = Assert.Single(cloud.HealthRows, r => r.Label == "Cloud connection");
        Assert.NotNull(link.Ok);
        Assert.Equal("health", link.Group);
    }
}
