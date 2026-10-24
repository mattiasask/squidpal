using System.Globalization;
using System.Text;

namespace DayLog.Core;

/// <summary>One line in the day file. Same fields and order as the macOS app.</summary>
public sealed class LogEvent
{
    public DateTimeOffset Ts = DateTimeOffset.Now;
    public string Event = "";           // focus, update, scroll, typing, selection, clipboard, leave
    public string? App;
    public string? BundleId;            // executable name on Windows, e.g. "chrome.exe"
    public string? WindowTitle;
    public string? Url;
    public string? PageTitle;
    public string? Text;
    public int Redactions;
    public Dictionary<string, int> RedactionKinds = new();
    public double? DwellSeconds;
}

/// <summary>Append-only JSONL writer. Each line is one write + flush to disk,
/// so a sync client never sees half a line. Parts roll at 50 MB.</summary>
public sealed class LogWriter
{
    public const long MaxFileBytes = 50L * 1024 * 1024;
    public string Folder { get; }
    public LogWriter(string folder) { Folder = folder; }

    public static string DayString(DateTimeOffset? d = null) =>
        (d ?? DateTimeOffset.Now).ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);

    public static string PartPath(string folder, string day, int part) =>
        Path.Combine(folder, part == 1 ? $"{day}.jsonl" : $"{day}-{part}.jsonl");

    public static List<string> DayFiles(string folder, string day)
    {
        var list = new List<string>();
        for (int part = 1; ; part++)
        {
            var p = PartPath(folder, day, part);
            if (!File.Exists(p)) break;
            list.Add(p);
        }
        return list;
    }

    public static long Size(string path)
    {
        try { return new FileInfo(path).Length; } catch { return 0; }
    }

    string CurrentFile(string day)
    {
        var existing = DayFiles(Folder, day);
        if (existing.Count == 0) return PartPath(Folder, day, 1);
        var last = existing[^1];
        return Size(last) >= MaxFileBytes ? PartPath(Folder, day, existing.Count + 1) : last;
    }

    static readonly string[] TsFormat = { "yyyy-MM-dd'T'HH:mm:ss.fffzzz" };

    public static string Serialize(LogEvent e)
    {
        var sb = new StringBuilder(256 + (e.Text?.Length ?? 0));
        sb.Append("{\"ts\":").Append(Json(e.Ts.ToString(TsFormat[0], CultureInfo.InvariantCulture)));
        sb.Append(",\"event\":").Append(Json(e.Event));
        sb.Append(",\"app\":").Append(Json(e.App));
        sb.Append(",\"bundle_id\":").Append(Json(e.BundleId));
        sb.Append(",\"window_title\":").Append(Json(e.WindowTitle));
        sb.Append(",\"url\":").Append(Json(e.Url));
        sb.Append(",\"page_title\":").Append(Json(e.PageTitle));
        sb.Append(",\"text\":").Append(Json(e.Text));
        sb.Append(",\"redactions\":").Append(e.Redactions.ToString(CultureInfo.InvariantCulture));
        if (e.RedactionKinds.Count > 0)
        {
            var parts = e.RedactionKinds.OrderBy(k => k.Key, StringComparer.Ordinal)
                .Select(k => $"{Json(k.Key)}:{k.Value.ToString(CultureInfo.InvariantCulture)}");
            sb.Append(",\"redaction_kinds\":{").Append(string.Join(",", parts)).Append('}');
        }
        sb.Append(",\"dwell_seconds\":")
          .Append(e.DwellSeconds is { } d ? d.ToString("0.0", CultureInfo.InvariantCulture) : "null");
        sb.Append('}');
        return sb.ToString();
    }

    /// <summary>Appends one line and flushes. Returns the byte length written.</summary>
    public int Append(LogEvent e)
    {
        var line = Serialize(e) + "\n";
        var data = Encoding.UTF8.GetBytes(line);
        var path = CurrentFile(DayString(e.Ts));
        using var fs = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.Read);
        fs.Write(data, 0, data.Length);
        fs.Flush(flushToDisk: true);
        return data.Length;
    }

    static string Json(string? s)
    {
        if (s is null) return "null";
        var sb = new StringBuilder(s.Length + 2);
        sb.Append('"');
        foreach (var ch in s)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                case '\u2028': sb.Append("\\u2028"); break;
                case '\u2029': sb.Append("\\u2029"); break;
                default:
                    if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(ch);
                    break;
            }
        }
        sb.Append('"');
        return sb.ToString();
    }
}
