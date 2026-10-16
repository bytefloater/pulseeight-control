using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace PulseEightControl;

public sealed class App : Application
{
    private MainWindow? _window;

    public App()
    {
        Resources.MergedDictionaries.Add(new XamlControlsResources());
        UnhandledException += (_, e) => CrashLog.Write(e.Exception);
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        try
        {
            _window = new MainWindow();
            _window.Activate();
        }
        catch (Exception exception)
        {
            CrashLog.Write(exception);
            throw;
        }
    }
}

/// <summary>Writes unexpected errors to %LOCALAPPDATA%\PulseEightControl\crash.log, since a
/// windowed app has no console to show them in.</summary>
internal static class CrashLog
{
    public static string Path => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PulseEightControl", "crash.log");

    public static void Write(Exception? exception)
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(Path)!);
            File.AppendAllText(Path, $"{DateTime.Now:O}\n{exception}\n\n");
        }
        catch (Exception) { /* nothing more can be done */ }
    }
}
