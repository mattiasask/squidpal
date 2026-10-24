using System.Text.Json;
using DayLog.Core;

// Runs the shared fixtures (shared/redaction-fixtures.json) against the C#
// Redactor. The same file is used by the macOS app, so the rules can't drift.
//   dotnet run --project DayLog.SelfTest -- [path-to-fixtures.json]

string path;
if (args.Length > 0)
{
    path = args[0];
}
else
{
    // Climb from the output dir until a repo-root "shared" folder is found.
    var dir = AppContext.BaseDirectory;
    while (dir != null && !File.Exists(Path.Combine(dir, "shared", "redaction-fixtures.json")))
        dir = Directory.GetParent(dir)?.FullName;
    path = dir != null
        ? Path.Combine(dir, "shared", "redaction-fixtures.json")
        : Path.Combine(AppContext.BaseDirectory, "shared", "redaction-fixtures.json");
}
path = Path.GetFullPath(path);
if (!File.Exists(path)) { Console.Error.WriteLine($"Hittar inte {path}"); return 2; }

using var doc = JsonDocument.Parse(File.ReadAllText(path));
int passed = 0, failed = 0;

void Report(string name, string? problem)
{
    if (problem is null) { passed++; Console.WriteLine($"ok    {name}"); }
    else { failed++; Console.WriteLine($"FAIL  {name}: {problem}"); }
}

foreach (var c in doc.RootElement.GetProperty("redaction").EnumerateArray())
{
    var name = c.GetProperty("name").GetString()!;
    var input = c.GetProperty("input").GetString()!;
    string? kind = c.GetProperty("kind").ValueKind == JsonValueKind.Null ? null : c.GetProperty("kind").GetString();
    var gone = c.GetProperty("gone").EnumerateArray().Select(x => x.GetString()!).ToList();
    var kept = c.GetProperty("kept").EnumerateArray().Select(x => x.GetString()!).ToList();

    var outp = Redactor.Redact(input);
    var problems = new List<string>();
    if (kind != null) { if (!outp.Text.Contains($"[REDACTED:{kind}]")) problems.Add($"expected [REDACTED:{kind}]"); }
    else if (outp.Count != 0) problems.Add($"expected no redaction, got [{string.Join(",", outp.Kinds)}]");
    foreach (var g in gone) if (outp.Text.Contains(g)) problems.Add($"still contains \"{g}\"");
    foreach (var k in kept) if (!outp.Text.Contains(k)) problems.Add($"lost \"{k}\"");
    var again = Redactor.Redact(outp.Text);
    if (again.Count != 0) problems.Add($"second pass redacted [{string.Join(",", again.Kinds)}]");
    Report(name, problems.Count == 0 ? null : string.Join("; ", problems) + " -> " + outp.Text);
}

foreach (var c in doc.RootElement.GetProperty("sensitive_field_names").EnumerateArray())
{
    var input = c.GetProperty("input").GetString()!;
    var expected = c.GetProperty("expected").GetBoolean();
    var got = Redactor.IsSensitiveFieldName(input);
    Report($"field: {input}", got == expected ? null : $"expected {expected}, got {got}");
}

// A couple of checks that have no natural fixture entry.
Report("luhn ok", Redactor.Luhn("4111111111111111") ? null : "expected true");
Report("luhn bad", !Redactor.Luhn("4111111111111112") ? null : "expected false");
Report("blocked app 1Password", Redactor.IsBlockedApp("1password.exe", "1Password") ? null : "expected true");
Report("blocked app Chrome", !Redactor.IsBlockedApp("chrome.exe", "Google Chrome") ? null : "expected false");

Console.WriteLine($"\n{passed} passed, {failed} failed");
return failed == 0 ? 0 : 1;
