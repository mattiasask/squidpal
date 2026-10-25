using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace DayLog.Win;

/// <summary>
/// Builds a faithful, human-readable HTML timeline from a day's JSONL files.
/// Self-contained (inline CSS, no network). Redaction markers [REDACTED:kind]
/// are shown as a lock chip, never expanded, so the viewer SEES what was hidden.
/// Shared design with the macOS/Linux builds.
/// </summary>
public static class Timeline
{
    sealed class Ev
    {
        public string Ts = "";
        public string Event = "";
        public string? App, Win, Url, Page, Text;
        public int Red;
        public double? Dwell;
    }

    sealed class Grp
    {
        public string Ts = "";
        public string? App, Win, Url, Page;
        public readonly List<Ev> Items = new();
        public double? Dwell;
        public int Red;
        public string Key = "";
    }

    /// <summary>Write the timeline HTML to a temp file; returns the path (or null).</summary>
    public static string? Build(IReadOnlyList<string> files, string day)
    {
        var events = ReadEvents(files);
        var groups = Group(events);
        int totalRed = events.Sum(e => e.Red);
        int apps = events.Where(e => !string.IsNullOrEmpty(e.App)).Select(e => e.App).Distinct().Count();

        string cards = groups.Count == 0
            ? "<div class=\"empty\">Inga poster för idag ännu.</div>"
            : string.Concat(groups.Select(GroupHtml));

        string doc = "<!doctype html><html lang=\"sv\"><head><meta charset=\"utf-8\">"
            + "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">"
            + $"<title>Squidpal — {Esc(day)}</title><style>{Css}</style></head>"
            + "<body><div class=\"wrap\"><header><h1>Squidpal</h1>"
            + $"<div class=\"date\">{Esc(PrettyDate(day))}</div>"
            + $"<div class=\"sub\">{events.Count} poster · {totalRed} maskeringar · {apps} appar</div>"
            + $"</header><main>{cards}</main>"
            + $"<footer>Genererad {DateTime.Now:HH:mm} · all data stannar lokalt på din dator</footer>"
            + "</div></body></html>";

        try
        {
            string path = Path.Combine(Path.GetTempPath(), $"squidpal-timeline-{day}.html");
            File.WriteAllText(path, doc, new UTF8Encoding(false));
            return path;
        }
        catch { return null; }
    }

    static List<Ev> ReadEvents(IReadOnlyList<string> files)
    {
        var list = new List<Ev>();
        foreach (var f in files)
        {
            string[] lines;
            try { lines = File.ReadAllLines(f); } catch { continue; }
            foreach (var raw in lines)
            {
                var line = raw.Trim();
                if (line.Length == 0) continue;
                try
                {
                    using var jdoc = JsonDocument.Parse(line);
                    var r = jdoc.RootElement;
                    if (r.ValueKind != JsonValueKind.Object) continue;
                    list.Add(new Ev
                    {
                        Ts = Str(r, "ts") ?? "",
                        Event = Str(r, "event") ?? "",
                        App = StrOrNull(r, "app"),
                        Win = StrOrNull(r, "window_title"),
                        Url = StrOrNull(r, "url"),
                        Page = StrOrNull(r, "page_title"),
                        Text = StrOrNull(r, "text"),
                        Red = IntOf(r, "redactions"),
                        Dwell = DoubleOrNull(r, "dwell_seconds"),
                    });
                }
                catch { }
            }
        }
        list.Sort((a, b) => string.CompareOrdinal(a.Ts, b.Ts));
        return list;
    }

    static List<Grp> Group(List<Ev> events)
    {
        var groups = new List<Grp>();
        foreach (var e in events)
        {
            string k = (e.App ?? "") + "\u0001" + (e.Win ?? "") + "\u0001" + (e.Url ?? "");
            if (e.Event == "focus" || groups.Count == 0 || groups[^1].Key != k)
                groups.Add(new Grp { Ts = e.Ts, App = e.App, Win = e.Win, Url = e.Url, Page = e.Page, Key = k });
            var g = groups[^1];
            g.Items.Add(e);
            g.Red += e.Red;
            if (e.Event == "leave" && e.Dwell is > 0) g.Dwell = e.Dwell;
        }
        return groups;
    }

    static string GroupHtml(Grp g)
    {
        var head = new StringBuilder();
        head.Append($"<span class=\"time\">{Hhmm(g.Ts)}</span>");
        head.Append($"<span class=\"app\">{Esc(g.App ?? "Okänd app")}</span>");
        if (!string.IsNullOrEmpty(g.Win)) head.Append($"<span class=\"win\">{Esc(g.Win!)}</span>");
        if (g.Dwell is { } d) head.Append($"<span class=\"dur\">· {FmtDur(d)}</span>");
        if (g.Red > 0) head.Append($"<span class=\"lock\" title=\"{g.Red} maskeringar i detta block\">🔒</span>");

        string urlLine = "";
        if (!string.IsNullOrEmpty(g.Url))
        {
            string label = (g.Page != null ? g.Page + " — " : "") + g.Url;
            urlLine = $"<div class=\"url\">{Esc(label)}</div>";
        }

        var body = new StringBuilder();
        foreach (var e in g.Items)
        {
            if (string.IsNullOrEmpty(e.Text)) continue;
            string tag = TagFor(e.Event);
            string tagHtml = tag.Length == 0 ? "" : $"<span class=\"tag\">{tag}</span>";
            body.Append($"<div class=\"ev\">{tagHtml}<div class=\"text\">{RenderText(e.Text!)}</div></div>");
        }
        string bodyHtml = body.Length == 0 ? "" : $"<div class=\"body\">{body}</div>";
        return $"<section class=\"card\"><div class=\"chead\">{head}</div>{urlLine}{bodyHtml}</section>";
    }

    static readonly Regex RedRe = new(@"\[REDACTED:([^\]]+)\]", RegexOptions.Compiled);

    static string RenderText(string t)
    {
        string escaped = Esc(t.Replace("\r\n", "\n").Replace("\r", "\n"));
        string replaced = RedRe.Replace(escaped,
            m => $"<span class=\"red\" title=\"dold: {Esc(m.Groups[1].Value)}\">🔒 dold</span>");
        return replaced.Replace("\n", "<br>");
    }

    static string Esc(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s)
            sb.Append(c switch
            {
                '&' => "&amp;",
                '<' => "&lt;",
                '>' => "&gt;",
                '"' => "&quot;",
                '\'' => "&#39;",
                _ => c.ToString(),
            });
        return sb.ToString();
    }

    static string? Str(JsonElement r, string k)
        => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    static string? StrOrNull(JsonElement r, string k)
    {
        var s = Str(r, k);
        return string.IsNullOrEmpty(s) ? null : s;
    }

    static int IntOf(JsonElement r, string k)
        => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var n) ? n : 0;

    static double? DoubleOrNull(JsonElement r, string k)
        => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetDouble(out var d) ? d : null;

    static string TagFor(string ev) => ev switch
    {
        "update" => "uppdaterade",
        "scroll" => "skrollade",
        "typing" => "skrev",
        "selection" => "markerade",
        "clipboard" => "kopierade",
        _ => "",
    };

    static string Hhmm(string ts) => ts.Length >= 16 ? ts.Substring(11, 5) : ts;

    static string FmtDur(double sec)
    {
        int s = (int)Math.Round(sec);
        if (s < 60) return $"{s}s";
        int m = s / 60, rs = s % 60;
        if (m < 60) return rs > 0 ? $"{m}m {rs}s" : $"{m}m";
        int h = m / 60, rm = m % 60;
        return rm > 0 ? $"{h}t {rm}m" : $"{h}t";
    }

    static readonly string[] WeekdaysSv =
        { "", "söndag", "måndag", "tisdag", "onsdag", "torsdag", "fredag", "lördag" };
    static readonly string[] MonthsSv =
        { "", "januari", "februari", "mars", "april", "maj", "juni",
          "juli", "augusti", "september", "oktober", "november", "december" };

    static string PrettyDate(string day)
    {
        var p = day.Split('-');
        if (p.Length != 3 || !int.TryParse(p[0], out int y)
            || !int.TryParse(p[1], out int mo) || !int.TryParse(p[2], out int d))
            return day;
        try
        {
            var dt = new DateTime(y, mo, d);
            string wdName = WeekdaysSv[(int)dt.DayOfWeek + 1];       // Sunday=0 -> index 1
            string moName = (mo >= 1 && mo <= 12) ? MonthsSv[mo] : "";
            string s = $"{wdName} {d} {moName} {y}";
            return char.ToUpper(s[0]) + s.Substring(1);
        }
        catch { return day; }
    }

    const string Css = """
    :root{--bg:#f6f3ec;--card:#fffdf8;--ink:#17293b;--muted:#6a7787;--line:#e7e0d3;
    --accent:#c2411f;--chip-bg:#efe7db;--chip-ink:#8a6038;--tag-bg:#e9eef2;--tag-ink:#5b6b7c}
    @media (prefers-color-scheme:dark){:root{--bg:#0e1a26;--card:#15222f;--ink:#e9eef3;
    --muted:#8599ab;--line:#223342;--accent:#e2683f;--chip-bg:#2a2016;--chip-ink:#e0b483;
    --tag-bg:#1d2b39;--tag-ink:#8fa3b6}}
    *{box-sizing:border-box}
    body{margin:0;background:var(--bg);color:var(--ink);
    font:15px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Ubuntu,sans-serif}
    .wrap{max-width:760px;margin:0 auto;padding:32px 16px 80px}
    header{margin-bottom:24px}
    h1{font-size:20px;margin:0 0 2px;letter-spacing:.2px}
    .date{color:var(--muted)}
    .sub{color:var(--muted);font-size:13px;margin-top:6px}
    .card{background:var(--card);border:1px solid var(--line);border-radius:12px;
    padding:14px 16px;margin:10px 0;box-shadow:0 1px 2px rgba(0,0,0,.03)}
    .chead{display:flex;flex-wrap:wrap;align-items:baseline;gap:8px}
    .time{font-variant-numeric:tabular-nums;color:var(--accent);font-weight:600;font-size:13px}
    .app{font-weight:650}
    .win{color:var(--muted)}
    .dur{color:var(--muted);font-size:13px}
    .lock{margin-left:auto;font-size:13px}
    .url{color:var(--muted);font-size:12.5px;margin-top:3px;word-break:break-all;
    font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace}
    .body{margin-top:10px;display:flex;flex-direction:column;gap:8px}
    .ev{display:flex;gap:8px;align-items:flex-start}
    .tag{flex:none;font-size:11px;text-transform:uppercase;letter-spacing:.4px;
    background:var(--tag-bg);color:var(--tag-ink);padding:2px 7px;border-radius:6px;margin-top:2px}
    .text{white-space:pre-wrap;word-break:break-word}
    .red{background:var(--chip-bg);color:var(--chip-ink);border-radius:5px;
    padding:0 6px;font-size:12.5px;white-space:nowrap}
    .empty{color:var(--muted);text-align:center;padding:60px 0}
    footer{color:var(--muted);font-size:12px;text-align:center;margin-top:30px}
    """;
}
