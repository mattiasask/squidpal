namespace DayLog.Core;

/// <summary>
/// Keeps, per app, the set of lines already written today, so a revisit to Gmail
/// or a long terminal scrollback only costs what is new. Also drops lines that are
/// our own JSONL records (so viewing/tailing the log does not record itself).
/// Reset at midnight, on folder change, on "delete today" and on restart.
/// </summary>
public sealed class LineDedup
{
    const int MaxPerApp = 300_000;
    readonly Dictionary<string, HashSet<int>> _seen = new();

    public void Reset() => _seen.Clear();

    /// <summary>Returns the lines of <paramref name="text"/> not yet written today
    /// for <paramref name="app"/> (null if none), own-log lines removed.</summary>
    public string? NewLines(string text, string? app)
    {
        var key = app ?? "?";
        if (!_seen.TryGetValue(key, out var set)) { set = new HashSet<int>(); _seen[key] = set; }
        if (set.Count > MaxPerApp) set.Clear();

        var kept = new List<string>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || IsOwnLogLine(line)) continue;
            if (set.Add(StableHash(line))) kept.Add(raw);
        }
        return kept.Count == 0 ? null : string.Join("\n", kept);
    }

    public static bool IsOwnLogLine(string line) =>
        line.StartsWith("{\"ts\":\"") || (line.Contains("\"event\":\"") && line.Contains("\"bundle_id\":"));

    public static bool LooksLikeOwnLog(string text) =>
        text.Split('\n').Take(3).Any(l => IsOwnLogLine(l.Trim()));

    // Deterministic 32-bit hash (string.GetHashCode is randomized per process).
    static int StableHash(string s)
    {
        unchecked
        {
            int h = 17;
            foreach (var c in s) h = h * 31 + c;
            return h;
        }
    }
}
