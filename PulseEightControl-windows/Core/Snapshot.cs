using System.Text.Json;
using System.Text.Json.Serialization;

namespace PulseEight.Core;

// The JSON contract of p8_snapshot (schema 1); see docs/core-interface.md.

/// <summary>A label and its text. Health rows also say whether the thing is in good order (<see cref="Ok"/>; null when the
/// matrix makes no judgement) and which <see cref="Group"/> they belong to: "health" or "diagnostics".</summary>
public sealed record LabeledValue(string Label, string Value, bool? Ok = null, string? Group = null);

public sealed record SettingsSnapshot(
    string Appearance, bool HighlightGrid, bool ShowStatusBar,
    string? Host, int Port, int Timeout, int PollInterval, int DetailPollInterval,
    string Language = "system", bool CheckForUpdates = true, bool? UpdatePrereleases = null);

/// <summary>One configured matrix. The admin password itself is never part of a snapshot.</summary>
public sealed record MatrixSnapshot(
    string Id, string Name, string DisplayName, string? Host, int Port,
    int Timeout, int PollInterval, int DetailPollInterval, bool AdminPasswordSaved, bool Selected)
{
    /// <summary>The address as the person types it: host, with ":port" when it isn't 80.</summary>
    public string Address => Host is { Length: > 0 } ? (Port == 80 ? Host : $"{Host}:{Port}") : "";
}

public sealed record LanguageSnapshot(string Code, string Name);

public sealed record PortSnapshot(
    string Mode, int Bay, int Number, string Name, string Type,
    int Status, string StatusLabel, int? ReceiveFrom, string? SourceName,
    bool UpdateAvailable, int? EdidProfile, IReadOnlyList<LabeledValue> Details)
{
    public bool IsInput => Mode == "Input";
}

public sealed record UpdateSnapshot(int Bay, string Name, string? FirmwareVersion);

public sealed record EdidSnapshot(int Id, string Name);

public sealed record FrontPanelSnapshot(string? Backlight, bool? StatusLed);

public sealed record Snapshot(
    int Schema, string Phase, string? PhaseDetail, string Summary, string HostLabel, bool AdminConfigured,
    string Language, IReadOnlyList<LanguageSnapshot> Languages,
    SettingsSnapshot Settings,
    IReadOnlyList<PortSnapshot> Inputs, IReadOnlyList<PortSnapshot> Outputs,
    IReadOnlyList<LabeledValue> SystemRows, IReadOnlyList<LabeledValue> FeatureRows,
    string? Model, string? Firmware, FrontPanelSnapshot? FrontPanel,
    IReadOnlyList<UpdateSnapshot> Updates, IReadOnlyList<EdidSnapshot> EdidProfiles)
{
    public const int SupportedSchema = 1;

    // Added with several matrices and the health report; a snapshot without them reads as none.
    /// <summary>Every configured matrix, in the order added.</summary>
    public IReadOnlyList<MatrixSnapshot> Matrices { get; init; } = [];
    /// <summary>The matrix's own health report, as rows; empty until it loads and for firmware without one.</summary>
    public IReadOnlyList<LabeledValue> HealthRows { get; init; } = [];
    /// <summary>Why the system details couldn't be loaded (they are missing while this is set).</summary>
    public string? SystemError { get; init; }

    public bool IsConnected => Phase == "connected";

    public MatrixSnapshot? SelectedMatrix => Matrices.FirstOrDefault(m => m.Selected);

    internal static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
    };

    public static Snapshot Parse(string json) =>
        JsonSerializer.Deserialize<Snapshot>(json, JsonOptions)
        ?? throw new InvalidOperationException("The core returned an empty snapshot");
}

/// <summary>Outcome of a command. <see cref="Error"/> is a message ready to show to the user.</summary>
public sealed record CommandResult(bool Ok, string? Error = null, string? Value = null)
{
    public static CommandResult Parse(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        var ok = root.TryGetProperty("ok", out var okElement) && okElement.GetBoolean();
        string? Text(string name) =>
            root.TryGetProperty(name, out var element) && element.ValueKind == JsonValueKind.String ? element.GetString() : null;
        return new CommandResult(ok, Text("error"), Text("value"));
    }
}

/// <summary>What <see cref="CoreClient.DiscoverAsync"/> found.</summary>
public sealed record DiscoveredMatrix(string Host, int Port);
