using PulseEight.Updates;
using Xunit;

namespace PulseEight.Updates.Tests;

public sealed class ReleaseInfoTests
{
    private static Dictionary<string, string?> Stamp(string version, string build, string channel, string label) => new()
    {
        [ReleaseInfo.VersionKey] = version, [ReleaseInfo.BuildKey] = build, [ReleaseInfo.ChannelKey] = channel, [ReleaseInfo.LabelKey] = label,
    };

    [Fact]
    public void AReleaseAReleaseCandidateAndABetaOfOneVersionReadDifferently()
    {
        var shown = new[]
        {
            ReleaseInfo.FromMetadata(Stamp("0.1.0", "0.1.0.300", "release", "Release"))!.Description,
            ReleaseInfo.FromMetadata(Stamp("0.1.0-rc.1", "0.1.0.201", "rc", "Release Candidate 1"))!.Description,
            ReleaseInfo.FromMetadata(Stamp("0.1.0-beta.12", "0.1.0.112", "beta", "Beta 12"))!.Description,
        };
        Assert.Equal(["0.1.0: Release (build 0.1.0.300)", "0.1.0: Release Candidate 1 (build 0.1.0.201)", "0.1.0: Beta 12 (build 0.1.0.112)"], shown);
        Assert.Equal(3, shown.Distinct().Count());
    }

    [Theory]
    [InlineData("release", false)]
    [InlineData("rc", true)]
    [InlineData("beta", true)]
    [InlineData("RC", true)]
    [InlineData("dev", false)]
    public void OnlyAReleaseCandidateOrBetaIsAPreRelease(string channel, bool expected) =>
        Assert.Equal(expected, ReleaseInfo.FromMetadata(Stamp("0.1.0", "0.1.0.1", channel, "x"))!.IsPrerelease);

    [Fact]
    public void ABuildWithoutAStampIsADevelopmentBuild()
    {
        Assert.Null(ReleaseInfo.FromMetadata(new Dictionary<string, string?>()));
        // A partial stamp isn't one.
        Assert.Null(ReleaseInfo.FromMetadata(new Dictionary<string, string?> { [ReleaseInfo.VersionKey] = "0.1.0" }));
        Assert.Null(ReleaseInfo.FromMetadata(Stamp("0.1.0", "  ", "release", "Release")));

        var development = ReleaseInfo.FromAssembly(typeof(ReleaseInfoTests).Assembly);
        Assert.True(development.IsDevelopment);
        Assert.False(development.IsPrerelease);
        Assert.Equal("Development build", development.Description);
    }

    [Fact]
    public void AStampedDevelopmentBuildIsStillADevelopmentBuild() =>
        Assert.Equal("Development build", ReleaseInfo.FromMetadata(Stamp("0.0.0-dev", "0.0.0.0", "dev", "Development build"))!.Description);
}
