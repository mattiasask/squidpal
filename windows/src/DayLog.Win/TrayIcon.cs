using System.Drawing;
using System.Reflection;
using Microsoft.Win32;

namespace DayLog.Win;

/// <summary>
/// Loads the Squidpal statolith tray icon from the brand .ico files embedded
/// in the assembly (see the .csproj — tray\*.ico is an EmbeddedResource, so the
/// icons survive single-file publish). Three states share the same rings:
/// recording (coral dot), paused (two bars), warning = "off" / not recording.
///
/// Windows does not tint tray icons, so we pick the glyph colour from the
/// taskbar theme: SystemUsesLightTheme 0/absent -> dark taskbar -> light glyph;
/// 1 -> light taskbar -> dark glyph.
/// </summary>
public static class TrayIcon
{
    public enum State { Recording, Paused, Warning }

    static readonly Assembly Asm = typeof(TrayIcon).Assembly;

    public static bool IsLightTaskbar()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(
                @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("SystemUsesLightTheme") is int v && v != 0;
        }
        catch { return false; }
    }

    static string FileFor(State state)
    {
        string name = state switch
        {
            State.Recording => "recording",
            State.Paused => "paused",
            _ => "off",
        };
        string theme = IsLightTaskbar() ? "dark" : "light";
        return $"tray-{name}-{theme}.ico";
    }

    /// <summary>Open an embedded tray icon by file name, matching on the
    /// resource-name suffix so we don't depend on the exact root namespace.</summary>
    static Stream OpenIcon(string fileName)
    {
        var resName = Array.Find(
            Asm.GetManifestResourceNames(),
            n => n.EndsWith(fileName, StringComparison.OrdinalIgnoreCase));
        var stream = resName is null ? null : Asm.GetManifestResourceStream(resName);
        return stream ?? throw new FileNotFoundException($"embedded tray icon not found: {fileName}");
    }

    /// <summary>Tray icon for a state at the current small-icon DPI size.
    /// Caller disposes.</summary>
    public static Icon Load(State state)
    {
        using var stream = OpenIcon(FileFor(state));
        return new Icon(stream, SystemInformation.SmallIconSize);
    }
}
