using System.Runtime.InteropServices;
using System.Text;
using PulseEight.Updates;
using Xunit;

namespace PulseEight.Updates.Tests;

public sealed class CheckingTests : IDisposable
{
    private readonly FeedFixture _feed = new();
    private static readonly byte[] Installer = Encoding.UTF8.GetBytes("pretend installer bytes");

    public void Dispose() => _feed.Dispose();

    [Fact]
    public async Task ANewerSignedReleaseIsOffered()
    {
        _feed.Publish(new ReleaseSpec("0.2.0.5", "0.2.0", Installer, Notes: "<ul><li>Faster</li></ul>"));
        using var service = _feed.NewService("0.1.0.1");

        var result = await service.CheckAsync();

        Assert.Equal(UpdateCheckStatus.Available, result.Status);
        var offer = Assert.IsType<UpdateOffer>(result.Offer);
        Assert.Equal("0.2.0.5", offer.Version);
        Assert.Equal("0.2.0", offer.DisplayVersion);
        Assert.Equal("<ul><li>Faster</li></ul>", offer.ReleaseNotesHtml);
        Assert.Equal(Installer.Length, offer.SizeBytes);
    }

    [Theory]
    [InlineData("0.2.0.5")] // the same version
    [InlineData("0.3.0.9")] // newer than the feed's newest
    public async Task NothingNewerMeansUpToDate(string installed)
    {
        _feed.Publish(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        using var service = _feed.NewService(installed);
        Assert.Equal(UpdateCheckStatus.UpToDate, (await service.CheckAsync()).Status);
    }

    [Fact]
    public async Task TheNewestOfSeveralReleasesIsTheOneOffered()
    {
        _feed.Publish(
            new ReleaseSpec("0.2.0.5", "0.2.0", Installer),
            new ReleaseSpec("0.10.0.20", "0.10.0", Installer),
            new ReleaseSpec("0.9.0.18", "0.9.0", Installer));
        using var service = _feed.NewService("0.1.0.1");
        Assert.Equal("0.10.0.20", (await service.CheckAsync()).Offer?.Version);
    }

    [Fact]
    public async Task ReleasesForOtherPlatformsAreIgnored()
    {
        _feed.Publish(new ReleaseSpec("0.9.0.9", "0.9.0", Installer, Os: ReleaseSpec.OtherOs));
        using var service = _feed.NewService("0.1.0.1");
        Assert.Equal(UpdateCheckStatus.UpToDate, (await service.CheckAsync()).Status);
    }

    [Fact]
    public async Task ASkippedVersionIsNotOfferedAgainButANewerOneIs()
    {
        _feed.Publish(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        using (var service = _feed.NewService("0.1.0.1"))
        {
            var offer = (await service.CheckAsync()).Offer!;
            service.Skip(offer);
            Assert.Equal(UpdateCheckStatus.UpToDate, (await service.CheckAsync()).Status);
        }

        // The choice is remembered across a restart of the app ...
        using (var restarted = _feed.NewService("0.1.0.1"))
            Assert.Equal(UpdateCheckStatus.UpToDate, (await restarted.CheckAsync()).Status);

        // ... but only for that version.
        _feed.Publish(new ReleaseSpec("0.3.0.7", "0.3.0", Installer));
        using var later = _feed.NewService("0.1.0.1");
        Assert.Equal("0.3.0.7", (await later.CheckAsync()).Offer?.Version);
    }

    [Fact]
    public async Task AFeedWithoutItsSignatureIsRefused()
    {
        _feed.Publish(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        _feed.Server.Remove("/appcast.xml.signature");
        using var service = _feed.NewService("0.1.0.1");

        var result = await service.CheckAsync();
        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.False(string.IsNullOrWhiteSpace(result.Error));
    }

    [Fact]
    public async Task AFeedSignedByTheWrongKeyIsRefused()
    {
        _feed.Publish(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        var impostor = new TestKey();
        _feed.Server.Serve("/appcast.xml.signature", impostor.Sign("whatever"));
        using var service = _feed.NewService("0.1.0.1");
        Assert.Equal(UpdateCheckStatus.Failed, (await service.CheckAsync()).Status);
    }

    [Fact]
    public async Task AFeedTamperedWithAfterSigningIsRefused()
    {
        _feed.Publish(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        // Change the feed (here, point the update elsewhere) but keep the old signature file.
        var xml = Encoding.UTF8.GetString(await new HttpClient().GetByteArrayAsync(_feed.FeedUrl));
        _feed.Server.Serve("/appcast.xml", xml.Replace("0.2.0.5", "9.9.9.9"));
        using var service = _feed.NewService("0.1.0.1");
        Assert.Equal(UpdateCheckStatus.Failed, (await service.CheckAsync()).Status);
    }

    [Fact]
    public async Task AFeedThatIsNotThereFailsWithAMessageNotAnException()
    {
        using var service = _feed.NewService("0.1.0.1", feedUrl: "http://127.0.0.1:1/appcast.xml");
        var result = await service.CheckAsync();
        Assert.Equal(UpdateCheckStatus.Failed, result.Status);
        Assert.False(string.IsNullOrWhiteSpace(result.Error));
    }

    [Fact]
    public async Task GarbageInsteadOfAFeedFailsCleanly()
    {
        _feed.Server.Serve("/appcast.xml", "this is not xml");
        _feed.Server.Serve("/appcast.xml.signature", _feed.Key.Sign("this is not xml"));
        using var service = _feed.NewService("0.1.0.1");
        Assert.Equal(UpdateCheckStatus.Failed, (await service.CheckAsync()).Status);
    }
}

public sealed class DownloadingTests : IDisposable
{
    private readonly FeedFixture _feed = new();
    private static readonly byte[] Installer = Enumerable.Range(0, 200_000).Select(i => (byte) (i * 31)).ToArray();

    public void Dispose() => _feed.Dispose();

    private async Task<(UpdateService Service, UpdateOffer Offer)> OfferAsync(ReleaseSpec release)
    {
        _feed.Publish(release);
        var service = _feed.NewService("0.1.0.1");
        var offer = (await service.CheckAsync()).Offer ?? throw new InvalidOperationException("No offer");
        return (service, offer);
    }

    [Fact]
    public async Task ASignedDownloadArrivesIntactAndReportsProgress()
    {
        var (service, offer) = await OfferAsync(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        using var _ = service;
        var reports = new List<UpdateProgress>();

        await service.DownloadAsync(offer, new Progress<UpdateProgress>(p => { lock (reports) reports.Add(p); }));
        await Task.Delay(100); // Progress<T> posts asynchronously

        var downloaded = Directory.GetFiles(Path.Combine(_feed.Folder, "downloads"), "*", SearchOption.AllDirectories);
        var file = Assert.Single(downloaded, f => new FileInfo(f).Length == Installer.Length);
        Assert.Equal(Installer, await File.ReadAllBytesAsync(file));
        lock (reports) Assert.NotEmpty(reports);
    }

    [Fact]
    public async Task ADownloadThatDoesNotMatchItsSignatureIsRefused()
    {
        // The feed promises a signature for different bytes than the file the server really has.
        var wrong = _feed.Key.Sign("some other file");
        var (service, offer) = await OfferAsync(new ReleaseSpec("0.2.0.5", "0.2.0", Installer, SignedWith: wrong));
        using var _ = service;

        var failure = await Assert.ThrowsAsync<UpdateException>(() => service.DownloadAsync(offer));
        Assert.Contains("signature", failure.Message, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public async Task ADownloadSignedByAnotherKeyIsRefused()
    {
        var impostor = new TestKey();
        var (service, offer) = await OfferAsync(new ReleaseSpec("0.2.0.5", "0.2.0", Installer, SignedWith: impostor.Sign(Installer)));
        using var _ = service;
        await Assert.ThrowsAsync<UpdateException>(() => service.DownloadAsync(offer));
    }

    [Fact]
    public async Task InstallingSomethingNeverDownloadedIsRefused()
    {
        var (service, offer) = await OfferAsync(new ReleaseSpec("0.2.0.5", "0.2.0", Installer));
        using var _ = service;
        await Assert.ThrowsAsync<UpdateException>(() => service.InstallAsync(offer));
    }
}

public sealed class SignatureCompatibilityTests
{
    /// <summary>The release tooling signs with scripts/release/ed25519.swift (CryptoKit). This is the check that what it
    /// produces is what NetSparkle's verifier on Windows accepts, using a signature the Swift tool actually made.</summary>
    [Fact]
    public void ASignatureFromTheSwiftSignerVerifiesWithNetSparkle()
    {
        var fixtures = Path.Combine(AppContext.BaseDirectory, "Fixtures");
        var publicKey = File.ReadAllText(Path.Combine(fixtures, "swift-signer.pub")).Trim();
        var signature = File.ReadAllText(Path.Combine(fixtures, "payload.bin.signature")).Trim();
        var payload = Path.Combine(fixtures, "payload.bin");

        var checker = new NetSparkleUpdater.SignatureVerifiers.Ed25519Checker(NetSparkleUpdater.Enums.SecurityMode.Strict, publicKey);

        Assert.Equal(NetSparkleUpdater.Enums.ValidationResult.Valid, checker.VerifySignatureOfFile(signature, payload));
        // And it is the signature for exactly these bytes, not a lenient check.
        var tampered = Path.Combine(Path.GetTempPath(), "p8-tampered-" + Guid.NewGuid().ToString("N"));
        File.WriteAllText(tampered, "different bytes");
        try { Assert.Equal(NetSparkleUpdater.Enums.ValidationResult.Invalid, checker.VerifySignatureOfFile(signature, tampered)); }
        finally { File.Delete(tampered); }
    }
}

public sealed class FeedNamingTests
{
    [Theory]
    [InlineData(Architecture.X64, "appcast-windows-x64.xml")]
    [InlineData(Architecture.Arm64, "appcast-windows-arm64.xml")]
    public void EachArchitectureHasItsOwnFeed(Architecture architecture, string expected) =>
        Assert.Equal(expected, UpdateFeeds.FileNameFor(architecture));

    [Fact]
    public void AnArchitectureWithoutAFeedIsAnErrorNotAGuess() =>
        Assert.Throws<PlatformNotSupportedException>(() => UpdateFeeds.FileNameFor(Architecture.X86));

    [Theory]
    [InlineData("https://example.com/releases")]
    [InlineData("https://example.com/releases/")]
    public void TheBaseUrlMayOrMayNotEndInASlash(string baseUrl) =>
        Assert.Equal("https://example.com/releases/appcast-windows-x64.xml", UpdateFeeds.UrlFor(baseUrl, Architecture.X64));
}

public sealed class ConfigurationTests
{
    [Fact]
    public void BothValuesMakeAConfiguration()
    {
        var configuration = UpdateConfiguration.FromMetadata(new Dictionary<string, string?>
        {
            [UpdateConfiguration.BaseUrlKey] = " https://example.com/r ",
            [UpdateConfiguration.PublicKeyKey] = "abc=",
        });
        Assert.Equal(new UpdateConfiguration("https://example.com/r", "abc="), configuration);
    }

    [Theory]
    [InlineData(null, "key")]
    [InlineData("", "key")]
    [InlineData("https://x", null)]
    [InlineData("https://x", "   ")]
    public void EitherMissingMeansNoUpdates(string? url, string? key) =>
        Assert.Null(UpdateConfiguration.FromMetadata(new Dictionary<string, string?>
        {
            [UpdateConfiguration.BaseUrlKey] = url,
            [UpdateConfiguration.PublicKeyKey] = key,
        }));

    [Fact]
    public void ADevelopmentAssemblyHasNoConfiguration() =>
        Assert.Null(UpdateConfiguration.FromAssembly(typeof(ConfigurationTests).Assembly));
}

public sealed class ReleaseNotesTextTests
{
    [Fact]
    public void AListBecomesBullets() =>
        Assert.Equal("• Faster\n• Fixes a crash", ReleaseNotesText.FromHtml("<ul>\n  <li>Faster</li>\n  <li>Fixes a crash</li>\n</ul>"));

    [Fact]
    public void ParagraphsAndBreaksKeepTheirLines() =>
        Assert.Equal("First paragraph.\n\nSecond.\nNext line.", ReleaseNotesText.FromHtml("<p>First paragraph.</p><p>Second.<br>Next line.</p>"));

    [Fact]
    public void EntitiesAreDecoded() =>
        Assert.Equal("Fish & chips <3", ReleaseNotesText.FromHtml("Fish &amp; chips &lt;3"));

    [Fact]
    public void ScriptsAndStylesAreRemovedWithTheirContents() =>
        Assert.Equal("Hello", ReleaseNotesText.FromHtml("<style>p{color:red}</style><script>alert('x')</script>Hello"));

    [Fact]
    public void MarkupIsDroppedNotInterpreted() =>
        Assert.Equal("Click here", ReleaseNotesText.FromHtml("<a href=\"https://evil.example\" onclick=\"steal()\">Click here</a>"));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("   \n ")]
    public void NothingIsNothing(string? html) => Assert.Equal("", ReleaseNotesText.FromHtml(html));

    [Fact]
    public void PlainTextPassesThrough() => Assert.Equal("Just words.", ReleaseNotesText.FromHtml("Just words."));

    [Fact]
    public void RunsOfBlankLinesAreCollapsed() =>
        Assert.Equal("A\n\nB", ReleaseNotesText.FromHtml("<p>A</p>\n\n\n\n<p>B</p>"));
}
