using System.Text.Json;

namespace DayLog.Win;

/// <summary>Chosen folder and per-day counters, in %APPDATA%\Squidpal.
/// Windows has no security-scoped bookmarks; a plain path persists fine.</summary>
internal static class Settings
{
    static readonly string Dir =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Squidpal");
    static readonly string SettingsPath = Path.Combine(Dir, "settings.json");

    sealed class Model { public string? Folder { get; set; } }

    public static string? Folder
    {
        get { return Load().Folder; }
        set { var m = Load(); m.Folder = value; Save(m); }
    }

    static Model Load()
    {
        try { return JsonSerializer.Deserialize<Model>(File.ReadAllText(SettingsPath)) ?? new Model(); }
        catch { return new Model(); }
    }

    static void Save(Model m)
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(SettingsPath, JsonSerializer.Serialize(m));
        }
        catch { /* best effort */ }
    }

    // Per-day counters, so the menu totals survive a restart.
    public static (int entries, int redactions) LoadCounters(string day)
    {
        try
        {
            var p = Path.Combine(Dir, $"stats-{day}.json");
            using var doc = JsonDocument.Parse(File.ReadAllText(p));
            return (doc.RootElement.GetProperty("entries").GetInt32(),
                    doc.RootElement.GetProperty("redactions").GetInt32());
        }
        catch { return (0, 0); }
    }

    public static void SaveCounters(string day, int entries, int redactions)
    {
        try
        {
            Directory.CreateDirectory(Dir);
            File.WriteAllText(Path.Combine(Dir, $"stats-{day}.json"),
                JsonSerializer.Serialize(new { entries, redactions }));
        }
        catch { }
    }

    public static void ClearCounters(string day)
    {
        try { File.Delete(Path.Combine(Dir, $"stats-{day}.json")); } catch { }
    }
}
