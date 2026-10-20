using System.Text;
using PulseEight.Updates;
using Xunit;

namespace PulseEight.Updates.Tests;

/// <summary>Release candidates and betas sit in the feed on a channel; a release has none. Everyone is offered a release;
/// a pre-release only goes to an app that asked for pre-releases.</summary>
public sealed class UpdateChannelTests : IDisposable
{
    private readonly FeedFixture _feed = new();
    private static readonly byte[] Installer = Encoding.UTF8.GetBytes("pretend installer bytes");

    public void Dispose() => _feed.Dispose();

    private static ReleaseSpec Release(string version, string tag) => new(version, tag, Installer);
    private static ReleaseSpec Rc(string version, string tag) => new(version, tag, Installer, Channel: "rc");
    private static ReleaseSpec Beta(string version, string tag) => new(version, tag, Installer, Channel: "beta");

    private async Task<string?> Offered(string installed, bool prereleases)
    {
        using var service = _feed.NewService(installed);
        service.IncludePrereleases = prereleases;
        var result = await service.CheckAsync();
        return result.Status == UpdateCheckStatus.Available ? result.Offer?.DisplayVersion : null;
    }

    [Fact]
    public async Task ByDefaultNoPreReleaseIsOffered()
    {
        _feed.Publish(Rc("0.2.0.201", "0.2.0-rc.1"), Beta("0.2.0.101", "0.2.0-beta.1"));
        using var service = _feed.NewService("0.1.0.300");
        Assert.False(service.IncludePrereleases);
        Assert.Equal(UpdateCheckStatus.UpToDate, (await service.CheckAsync()).Status);
    }

    [Fact]
    public async Task AReleaseCandidateIsOfferedWhenPreReleasesAreOn() =>
        Assert.Equal("0.2.0-rc.1", await ThenOffered("0.1.0.300", true, Rc("0.2.0.201", "0.2.0-rc.1")));

    [Fact]
    public async Task ABetaIsOfferedWhenPreReleasesAreOn() =>
        Assert.Equal("0.2.0-beta.1", await ThenOffered("0.1.0.300", true, Beta("0.2.0.101", "0.2.0-beta.1")));

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task AReleaseIsAlwaysOffered(bool prereleases) =>
        Assert.Equal("0.2.0", await ThenOffered("0.1.0.300", prereleases, Release("0.2.0.300", "0.2.0")));

    [Fact]
    public async Task WithPreReleasesOffTheNewestReleaseIsOfferedNotThePreReleaseAfterIt()
    {
        // 0.3.0 rc is newer than the 0.2.0 release, but not offered to someone who didn't ask for pre-releases.
        _feed.Publish(Release("0.2.0.300", "0.2.0"), Rc("0.3.0.201", "0.3.0-rc.1"));
        Assert.Equal("0.2.0", await Offered("0.1.0.300", prereleases: false));
        Assert.Equal("0.3.0-rc.1", await Offered("0.1.0.300", prereleases: true));
    }

    [Fact]
    public async Task TheNewestOfTheEligibleItemsWinsAcrossChannels()
    {
        _feed.Publish(Beta("0.2.0.102", "0.2.0-beta.2"), Rc("0.2.0.201", "0.2.0-rc.1"), Release("0.2.0.300", "0.2.0"));
        Assert.Equal("0.2.0", await Offered("0.1.0.300", prereleases: true));
        Assert.Equal("0.2.0", await Offered("0.1.0.300", prereleases: false));
        // The release is newer than the release candidate.
        Assert.Equal("0.2.0", await Offered("0.2.0.102", prereleases: true));
    }

    [Fact]
    public async Task APersonOnABetaIsOfferedTheNextReleaseCandidateBeforeTheReleaseExists()
    {
        _feed.Publish(Beta("0.2.0.102", "0.2.0-beta.2"), Rc("0.2.0.201", "0.2.0-rc.1"));
        Assert.Equal("0.2.0-rc.1", await Offered("0.2.0.102", prereleases: true));
        // And nothing if they turned pre-releases off.
        Assert.Null(await Offered("0.2.0.102", prereleases: false));
    }

    [Fact]
    public async Task APreReleaseBuildIsOfferedTheReleaseOfItsVersionEvenWithPreReleasesOff()
    {
        _feed.Publish(Rc("0.2.0.201", "0.2.0-rc.1"), Release("0.2.0.300", "0.2.0"));
        Assert.Equal("0.2.0", await Offered("0.2.0.201", prereleases: false));
    }

    [Fact]
    public async Task APreReleaseThatIsNotNewerThanWhatIsInstalledIsNotOffered()
    {
        _feed.Publish(Rc("0.2.0.201", "0.2.0-rc.1"));
        Assert.Null(await Offered("0.2.0.300", prereleases: true));
        Assert.Null(await Offered("0.2.0.201", prereleases: true));
    }

    [Fact]
    public async Task TheChoiceTakesEffectAtTheNextCheckOnTheSameService()
    {
        _feed.Publish(Rc("0.2.0.201", "0.2.0-rc.1"));
        using var service = _feed.NewService("0.1.0.300");
        Assert.Equal(UpdateCheckStatus.UpToDate, (await service.CheckAsync()).Status);

        service.IncludePrereleases = true;
        Assert.Equal("0.2.0-rc.1", (await service.CheckAsync()).Offer?.DisplayVersion);

        service.IncludePrereleases = false;
        Assert.Equal(UpdateCheckStatus.UpToDate, (await service.CheckAsync()).Status);
    }

    [Theory]
    [InlineData("RC")]
    [InlineData("Beta")]
    public async Task ChannelNamesAreNotCaseSensitive(string channel) =>
        Assert.NotNull(await ThenOffered("0.1.0.300", true, new ReleaseSpec("0.2.0.201", "0.2.0-x.1", Installer, Channel: channel)));

    [Theory]
    [InlineData("nightly")]
    [InlineData("stable")]
    public async Task AnUnknownChannelIsNeverOffered(string channel) =>
        Assert.Null(await ThenOffered("0.1.0.300", true, new ReleaseSpec("0.2.0.300", "0.2.0", Installer, Channel: channel)));

    private async Task<string?> ThenOffered(string installed, bool prereleases, params ReleaseSpec[] feed)
    {
        _feed.Publish(feed);
        return await Offered(installed, prereleases);
    }
}
