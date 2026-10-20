using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using NSec.Cryptography;
using PulseEight.Updates;

namespace PulseEight.Updates.Tests;

/// <summary>A very small HTTP server on a free port: GET only, one request per connection. Used instead of
/// HttpListener, which needs a URL reservation (an administrator) on Windows.</summary>
public sealed class MiniServer : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource _stop = new();
    private readonly ConcurrentDictionary<string, byte[]> _files = new();
    private int _requests;

    public MiniServer()
    {
        _listener.Start();
        _ = Task.Run(AcceptLoop);
    }

    public string BaseUrl => $"http://127.0.0.1:{((IPEndPoint) _listener.LocalEndpoint).Port}";
    public int Requests => Volatile.Read(ref _requests);

    public void Serve(string path, byte[] content) => _files[path] = content;
    public void Serve(string path, string content) => Serve(path, Encoding.UTF8.GetBytes(content));
    public void Remove(string path) => _files.TryRemove(path, out _);

    private async Task AcceptLoop()
    {
        while (!_stop.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
            catch { return; }
            _ = Task.Run(() => Handle(client));
        }
    }

    private async Task Handle(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var buffer = new byte[8192];
                var read = await stream.ReadAsync(buffer);
                var request = Encoding.ASCII.GetString(buffer, 0, read);
                var path = request.Split(' ', 3).ElementAtOrDefault(1) ?? "/";
                path = path.Split('?')[0];
                Interlocked.Increment(ref _requests);

                var found = _files.TryGetValue(path, out var body);
                var head = Encoding.ASCII.GetBytes(
                    $"HTTP/1.1 {(found ? "200 OK" : "404 Not Found")}\r\nContent-Length: {(found ? body!.Length : 0)}\r\nConnection: close\r\n\r\n");
                await stream.WriteAsync(head);
                if (found) await stream.WriteAsync(body!);
            }
            catch { /* a client that hung up */ }
        }
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
    }
}

/// <summary>An Ed25519 key that signs the way the release scripts do: a pure signature over the bytes, base64.</summary>
public sealed class TestKey
{
    private readonly Key _key = Key.Create(SignatureAlgorithm.Ed25519, new KeyCreationParameters { ExportPolicy = KeyExportPolicies.AllowPlaintextExport });

    public string PublicKey => Convert.ToBase64String(_key.PublicKey.Export(KeyBlobFormat.RawPublicKey));
    public string Sign(byte[] data) => Convert.ToBase64String(SignatureAlgorithm.Ed25519.Sign(_key, data));
    public string Sign(string text) => Sign(Encoding.UTF8.GetBytes(text));
}

public sealed record ReleaseSpec(
    string Version, string Short, byte[] Installer, string? Os = null, string? Notes = null, string? SignedWith = null,
    string? Channel = null)
{
    /// <summary>NetSparkle only offers items for the OS it runs on, and these tests run on whatever OS builds them,
    /// so "this platform's" release is marked with the host's own name (in production that is always windows).</summary>
    public static string HostOs { get; } = OperatingSystem.IsWindows() ? "windows" : OperatingSystem.IsMacOS() ? "macos" : "linux";

    /// <summary>An OS that is certainly not this one.</summary>
    public static string OtherOs { get; } = HostOs == "windows" ? "macos" : "windows";
}

/// <summary>Builds a feed, signs it, and serves everything from a MiniServer.</summary>
public sealed class FeedFixture : IDisposable
{
    public MiniServer Server { get; } = new();
    public TestKey Key { get; } = new();
    public string Folder { get; } = Directory.CreateTempSubdirectory("p8-updates-").FullName;
    public string FeedUrl => Server.BaseUrl + "/appcast.xml";

    public FeedFixture Publish(params ReleaseSpec[] releases)
    {
        var items = new StringBuilder();
        foreach (var release in releases)
        {
            var file = $"/PulseEightControl-{release.Short}-setup.exe";
            Server.Serve(file, release.Installer);
            var signature = release.SignedWith ?? Key.Sign(release.Installer);
            var os = $" sparkle:os=\"{release.Os ?? ReleaseSpec.HostOs}\"";
            var notes = release.Notes is null ? "" : $"<description><![CDATA[{release.Notes}]]></description>";
            var channel = release.Channel is null ? "" : $"<sparkle:channel>{release.Channel}</sparkle:channel>";
            items.Append($"""
                <item>
                  <title>{release.Short}</title>
                  <pubDate>Sat, 17 Oct 2026 12:00:00 +0000</pubDate>
                  <sparkle:version>{release.Version}</sparkle:version>
                  <sparkle:shortVersionString>{release.Short}</sparkle:shortVersionString>
                  {channel}
                  {notes}
                  <enclosure url="{Server.BaseUrl}{file}" length="{release.Installer.Length}" type="application/octet-stream"{os} sparkle:signature="{signature}" />
                </item>
                """);
        }
        var xml = $"""
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><title>Test feed</title>{items}</channel>
            </rss>
            """;
        Server.Serve("/appcast.xml", xml);
        Server.Serve("/appcast.xml.signature", Key.Sign(xml));
        return this;
    }

    public UpdateService NewService(string installedVersion = "0.1.0.1", string? feedUrl = null, string? publicKey = null) =>
        new(new UpdateOptions(
            feedUrl ?? FeedUrl,
            publicKey ?? Key.PublicKey,
            installedVersion,
            "PulseEight Control (test)",
            Path.Combine(Folder, "state.json"),
            Path.Combine(Folder, "downloads")));

    public void Dispose()
    {
        Server.Dispose();
        try { Directory.Delete(Folder, true); } catch { /* best effort */ }
    }
}
