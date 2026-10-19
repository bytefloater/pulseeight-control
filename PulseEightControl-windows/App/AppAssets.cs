namespace PulseEightControl;

/// <summary>Where the files in <c>Assets</c> are at run time: beside the executable, copied there by the build (see the
/// project file) and carried into the installer with everything else in the app folder.</summary>
internal static class AppAssets
{
    public static string Path(string file) => System.IO.Path.Combine(AppContext.BaseDirectory, "Assets", file);

    /// <summary>The path of an asset, or null if the file isn't there (a missing logo is never a reason to fail).</summary>
    public static string? Find(string file)
    {
        var path = Path(file);
        return File.Exists(path) ? path : null;
    }
}
