using System.Reflection;
using System.Runtime.InteropServices;

namespace PulseEight.Core;

/// <summary>The C interface of pulseeight_core (swift/include/pulseeight_core.h).</summary>
internal static class NativeMethods
{
    public const string Library = "pulseeight_core";

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    public delegate void Observer(IntPtr context, IntPtr snapshotJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern int p8_abi_version();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr p8_create();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern void p8_destroy(IntPtr core);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr p8_snapshot(IntPtr core);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr p8_call(IntPtr core, [MarshalAs(UnmanagedType.LPUTF8Str)] string requestJson);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern void p8_set_observer(IntPtr core, IntPtr callback, IntPtr context);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    public static extern void p8_free_string(IntPtr text);

    /// <summary>Copies a library-owned string into managed memory and frees the original.</summary>
    public static string TakeString(IntPtr pointer)
    {
        if (pointer == IntPtr.Zero) return "";
        try { return Marshal.PtrToStringUTF8(pointer) ?? ""; }
        finally { p8_free_string(pointer); }
    }

    static NativeMethods()
    {
        // P8_CORE_LIBRARY points at the library explicitly (development and tests); otherwise the
        // default probing finds pulseeight_core.dll beside the app.
        NativeLibrary.SetDllImportResolver(typeof(NativeMethods).Assembly, Resolve);
    }

    private static IntPtr Resolve(string name, Assembly assembly, DllImportSearchPath? path)
    {
        if (name != Library) return IntPtr.Zero;
        var explicitPath = Environment.GetEnvironmentVariable("P8_CORE_LIBRARY");
        return string.IsNullOrEmpty(explicitPath) ? IntPtr.Zero : NativeLibrary.Load(explicitPath);
    }
}
