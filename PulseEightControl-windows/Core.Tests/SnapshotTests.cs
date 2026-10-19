using PulseEight.Core;
using Xunit;

namespace PulseEight.Core.Tests;

public sealed class SnapshotTests
{
    [Fact]
    public void ParsesTheCoreSnapshotShape()
    {
        const string json = """
        {"schema":1,"phase":"connected","summary":"Connected to 10.0.0.2","hostLabel":"10.0.0.2","adminConfigured":true,"language":"en","languages":[{"code":"en","name":"English"}],
         "settings":{"appearance":"system","highlightGrid":true,"showStatusBar":true,"language":"system","host":"10.0.0.2","port":80,"timeout":10,"pollInterval":5,"detailPollInterval":20},
         "inputs":[{"mode":"Input","bay":0,"number":1,"name":"Sky","type":"HDMI IN","status":0,"statusLabel":"OK","updateAvailable":false,"edidProfile":3,"details":[{"label":"Signal","value":"HDMI"}]}],
         "outputs":[{"mode":"Output","bay":0,"number":1,"name":"Lounge","type":"HDBT OUT","status":3,"statusLabel":"No signal","receiveFrom":0,"sourceName":"Sky","updateAvailable":true,"details":[]}],
         "systemRows":[{"label":"Model","value":"NeoMatrix"}],"featureRows":[],
         "frontPanel":{"backlight":"high","statusLed":true},
         "updates":[{"bay":0,"name":"Lounge","firmwareVersion":"1.2"}],"edidProfiles":[{"id":0,"name":"Default"}]}
        """;

        var snapshot = Snapshot.Parse(json);

        Assert.True(snapshot.IsConnected);
        Assert.True(snapshot.Inputs[0].IsInput);
        Assert.Equal(3, snapshot.Inputs[0].EdidProfile);
        Assert.Equal("Sky", snapshot.Outputs[0].SourceName);
        Assert.Equal(3, snapshot.Outputs[0].Status);
        Assert.Null(snapshot.Model);
        Assert.Equal("high", snapshot.FrontPanel?.Backlight);
        Assert.Equal("Model", snapshot.SystemRows[0].Label);
        Assert.Single(snapshot.Updates);
        Assert.Equal("en", snapshot.Language);
        Assert.Equal("English", snapshot.Languages[0].Name);
        Assert.Equal("system", snapshot.Settings.Language);
        Assert.True(snapshot.Settings.CheckForUpdates, "a snapshot without the field means updates stay on");
    }

    [Fact]
    public void ReadsTheUpdateCheckSetting()
    {
        const string json = """
        {"schema":1,"phase":"notConfigured","summary":"","hostLabel":"","adminConfigured":false,"language":"en","languages":[],
         "settings":{"appearance":"system","highlightGrid":true,"showStatusBar":true,"checkForUpdates":false,"language":"system","port":80,"timeout":10,"pollInterval":5,"detailPollInterval":20},
         "inputs":[],"outputs":[],"systemRows":[],"featureRows":[],"updates":[],"edidProfiles":[]}
        """;
        Assert.False(Snapshot.Parse(json).Settings.CheckForUpdates);
    }

    [Fact]
    public void ReadsTheMatricesHealthRowsAndSystemError()
    {
        const string json = """
        {"schema":1,"phase":"connected","summary":"","hostLabel":"Lounge","adminConfigured":false,"language":"en","languages":[],
         "settings":{"appearance":"system","highlightGrid":true,"showStatusBar":true,"language":"system","port":80,"timeout":10,"pollInterval":5,"detailPollInterval":20},
         "matrices":[
           {"id":"a","name":"Lounge","displayName":"Lounge","host":"10.0.0.2","port":80,"timeout":10,"pollInterval":5,"detailPollInterval":20,"adminPasswordSaved":true,"selected":true},
           {"id":"b","name":"","displayName":"10.0.0.3","host":"10.0.0.3","port":8080,"timeout":10,"pollInterval":5,"detailPollInterval":20,"adminPasswordSaved":false,"selected":false}],
         "inputs":[],"outputs":[],"systemError":"HTTP 500","systemRows":[],"healthRows":[{"label":"Status","value":"OK","ok":true,"group":"health"},{"label":"Temperature 1","value":"31 °C","group":"diagnostics"}],"featureRows":[],"updates":[],"edidProfiles":[]}
        """;

        var snapshot = Snapshot.Parse(json);

        Assert.Equal(2, snapshot.Matrices.Count);
        Assert.Equal("a", snapshot.SelectedMatrix?.Id);
        Assert.Equal("10.0.0.2", snapshot.Matrices[0].Address);
        Assert.Equal("10.0.0.3:8080", snapshot.Matrices[1].Address);
        Assert.True(snapshot.Matrices[0].AdminPasswordSaved);
        Assert.Equal("HTTP 500", snapshot.SystemError);
        Assert.Equal(2, snapshot.HealthRows.Count);
        Assert.True(snapshot.HealthRows[0].Ok);
        Assert.Equal("health", snapshot.HealthRows[0].Group);
        Assert.Null(snapshot.HealthRows[1].Ok);
        Assert.Equal("diagnostics", snapshot.HealthRows[1].Group);
    }

    [Fact]
    public void AnOlderSnapshotReadsAsNoMatricesAndNoHealth()
    {
        const string json = """
        {"schema":1,"phase":"notConfigured","summary":"","hostLabel":"","adminConfigured":false,"language":"en","languages":[],
         "settings":{"appearance":"system","highlightGrid":true,"showStatusBar":true,"language":"system","port":80,"timeout":10,"pollInterval":5,"detailPollInterval":20},
         "inputs":[],"outputs":[],"systemRows":[],"featureRows":[],"updates":[],"edidProfiles":[]}
        """;

        var snapshot = Snapshot.Parse(json);

        Assert.Empty(snapshot.Matrices);
        Assert.Null(snapshot.SelectedMatrix);
        Assert.Empty(snapshot.HealthRows);
        Assert.Null(snapshot.SystemError);
    }

    [Fact]
    public void ParsesCommandResults()
    {
        Assert.True(CommandResult.Parse("""{"ok":true}""").Ok);
        Assert.Equal("Hi", CommandResult.Parse("""{"ok":true,"value":"Hi"}""").Value);
        var failure = CommandResult.Parse("""{"ok":false,"error":"Nope"}""");
        Assert.False(failure.Ok);
        Assert.Equal("Nope", failure.Error);
    }
}
