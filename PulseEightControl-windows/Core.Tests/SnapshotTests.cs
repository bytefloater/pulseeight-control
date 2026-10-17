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
    public void ParsesCommandResults()
    {
        Assert.True(CommandResult.Parse("""{"ok":true}""").Ok);
        Assert.Equal("Hi", CommandResult.Parse("""{"ok":true,"value":"Hi"}""").Value);
        var failure = CommandResult.Parse("""{"ok":false,"error":"Nope"}""");
        Assert.False(failure.Ok);
        Assert.Equal("Nope", failure.Error);
    }
}
