using System.Text.Json;
using System.Text.Json.Serialization;

namespace PulseEight.Core;

// The JSON contract of p8_snapshot (schema 1); see docs/core-interface.md.

public sealed record LabeledValue(string Label, string Value);

public sealed record SettingsSnapshot(
    string Appearance, bool HighlightGrid, bool ShowStatusBar,
    string? Host, int Port, int Timeout, int PollInterval, int DetailPollInterval);

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
    SettingsSnapshot Settings,
    IReadOnlyList<PortSnapshot> Inputs, IReadOnlyList<PortSnapshot> Outputs,
    IReadOnlyList<LabeledValue> SystemRows, IReadOnlyList<LabeledValue> FeatureRows,
    string? Model, string? Firmware, FrontPanelSnapshot? FrontPanel,
    IReadOnlyList<UpdateSnapshot> Updates, IReadOnlyList<EdidSnapshot> EdidProfiles)
{
    public const int SupportedSchema = 1;

    public bool IsConnected => Phase == "connected";

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
