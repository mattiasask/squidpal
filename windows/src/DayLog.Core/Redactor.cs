using System.Text;
using System.Text.RegularExpressions;

namespace DayLog.Core;

/// <summary>Result of running text through the redactor. Kinds, never values.</summary>
public sealed record RedactionOutput(string Text, int Count, IReadOnlyList<string> Kinds);

/// <summary>
/// All secret handling. Port of RedactorCore/Redactor.swift (macOS); both are
/// tested against shared/redaction-fixtures.json. String offsets are UTF-16 in
/// both .NET and NSString, so the rules line up one to one.
///
///  1. IsSensitiveField*  – fields that must never be read.
///  2. IsConcealedClipboard – clipboard marked by password managers.
///  3. IsBlockedApp       – password managers: record the app name only.
///  4. Regex rules        – key formats, PEM, key=value, URL creds, cards, personnummer, OTP.
///  5. Entropy pass       – long random-looking tokens.
/// </summary>
public static class Redactor
{
    public const string Marker = "[REDACTED:";
    const RegexOptions Base = RegexOptions.CultureInvariant | RegexOptions.Compiled;
    const RegexOptions CI = Base | RegexOptions.IgnoreCase;

    // ---------------------------------------------------------------- Layer 1

    static readonly string[] SubstringFieldWords =
    {
        "password", "passwd", "lösenord", "losenord", "passcode", "secret", "token",
        "säkerhetskod", "sakerhetskod", "pinkod", "engångskod", "engangskod",
    };
    static readonly Regex[] BoundedFieldWords =
        new[] { "pin", "otp", "2fa", "cvc", "cvv", "cvv2" }
            .Select(w => new Regex($@"(?<!\p{{L}}){w}(?!\p{{L}})", Base)).ToArray();
    static readonly Regex CamelSplit = new(@"(\p{Ll})(\p{Lu})", Base);

    /// <summary>True if a label, placeholder, id or name suggests a secret.</summary>
    public static bool IsSensitiveFieldName(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return false;
        var spaced = CamelSplit.Replace(raw, "$1 $2").ToLowerInvariant();
        if (SubstringFieldWords.Any(spaced.Contains)) return true;
        return BoundedFieldWords.Any(r => r.IsMatch(spaced));
    }

    public static bool IsSensitiveField(bool isPassword, IEnumerable<string?> names) =>
        isPassword || names.Any(IsSensitiveFieldName);

    // ---------------------------------------------------------------- Layer 2

    /// <summary>Windows clipboard formats that password managers and the OS use
    /// to say "do not record this".</summary>
    public static readonly HashSet<string> ConcealedClipboardFormats = new(StringComparer.OrdinalIgnoreCase)
    {
        "ExcludeClipboardContentFromMonitorProcessing",
        "Clipboard Viewer Ignore",
        // macOS names, kept so the rule is the same everywhere
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
    };

    public static bool IsConcealedClipboard(IEnumerable<string> formats) =>
        formats.Any(ConcealedClipboardFormats.Contains);

    // ---------------------------------------------------------------- Layer 3

    static readonly HashSet<string> BlockedExecutables = new(StringComparer.OrdinalIgnoreCase)
    {
        "1password.exe", "bitwarden.exe", "dashlane.exe", "keepass.exe", "keepassxc.exe",
        "lastpass.exe", "nordpass.exe", "enpass.exe", "roboform.exe", "keeper.exe",
        "credentialuibroker.exe",           // Windows credential prompt
    };
    static readonly string[] BlockedNameWords =
        { "1password", "bitwarden", "dashlane", "keepass", "lastpass", "nordpass", "enpass",
          "keeper", "roboform", "strongbox", "proton pass", "keychain", "nyckelhanteraren",
          "gnome-keyring", "seahorse" };

    /// <param name="appId">Executable name on Windows (bundle id on macOS).</param>
    public static bool IsBlockedApp(string? appId, string? name)
    {
        if (appId != null && BlockedExecutables.Contains(appId)) return true;
        var n = (name ?? "").ToLowerInvariant();
        if (n is "lösenord" or "passwords") return true;
        return BlockedNameWords.Any(n.Contains);
    }

    // ---------------------------------------------------------------- Layer 4

    delegate bool Validator(string value, Match match, string whole);

    sealed record Rule(string Kind, Regex Regex, int Group = 0, Validator? Validate = null);

    static Rule R(string kind, string pattern, int group = 0, bool ci = false, Validator? v = null) =>
        new(kind, new Regex(pattern, ci ? CI : Base), group, v);

    /// <summary>Whole words only, plus listed compounds ("verifieringskod", "passcode").</summary>
    static readonly Regex OtpContext = new(
        @"(?<!\p{L})(?:(?:verifierings|säkerhets|engångs|bekräftelse|inloggnings|login|pass|sms-?)?kod(?:en)?|(?:pass)?code|otp|bankid|2fa|verifi\p{L}*|one-time)(?!\p{L})",
        CI);
    const int OtpContextBefore = 30, OtpContextAfter = 12;

    /// <summary>Order matters: most specific first.</summary>
    static readonly Rule[] Rules =
    {
        R("private_key", @"-----BEGIN [A-Z0-9 ]*KEY-----[\s\S]*?-----END [A-Z0-9 ]*KEY-----"),
        R("api_key", @"sk-ant-[A-Za-z0-9_\-]{16,}"),
        R("api_key", @"(?<![A-Za-z0-9])(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"),
        R("webhook_secret", @"(?<![A-Za-z0-9])whsec_[A-Za-z0-9+/=]{20,}"),
        R("api_key", @"(?<![A-Za-z0-9])lin_api_[A-Za-z0-9]{30,}"),
        R("api_key", @"(?<![A-Za-z0-9])hf_[A-Za-z0-9]{30,}"),
        R("api_key", @"(?<![A-Za-z0-9_\-])sk-(?:proj-|live-|test-)?[A-Za-z0-9_\-]{20,}"),
        R("github_token", @"(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})"),
        R("slack_token", @"(?<![A-Za-z0-9])xox[abposr]-[A-Za-z0-9\-]{10,}"),
        R("aws_key", @"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])"),
        R("google_api_key", @"(?<![A-Za-z0-9])AIza[0-9A-Za-z_\-]{35}"),
        R("gitlab_token", @"(?<![A-Za-z0-9])glpat-[A-Za-z0-9_\-]{20,}"),
        R("npm_token", @"(?<![A-Za-z0-9])npm_[A-Za-z0-9]{36,}"),
        R("jwt", @"(?<![A-Za-z0-9_\-])eyJ[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}\.[A-Za-z0-9_\-]{5,}"),
        R("bearer_token", @"\bBearer\s+([A-Za-z0-9\-._~+/]{16,}=*)", group: 1, ci: true),
        R("url_credentials", @"\b[a-z][a-z0-9+.\-]*://([^\s:/@\[\]]+:[^\s/@\[\]]+)@", group: 1, ci: true),
        R("url_param",
          @"[?&#;](?:token|key|api_key|apikey|sig|signature|code|access_token|refresh_token|id_token|password|pwd|passwd|secret|client_secret|auth)=([^&#\s""'<>]+)",
          group: 1, ci: true),
        R("secret",
          @"(?<![\p{L}\p{N}])(?:password|passwd|pwd|lösenord|losenord|secret|token|api[_\-]?key|apikey|access[_\-]?key|client[_\-]?secret|private[_\-]?key|auth)(?:[_\-][A-Za-z0-9_]*)?(?![\p{L}\p{N}])[""']?\s*[:=]\s*[""']?([^\s""',;\[\]\{\}]+)",
          group: 1, ci: true),
        R("personnummer", @"(?<![0-9\-])((?:19|20)?[0-9]{6}[\-+]?[0-9]{4})(?![0-9])", group: 1,
          v: (value, _, _) => IsPersonnummer(value)),
        // Card numbers start with 2–6. IDs inside URLs/URNs (after : / = …) are left alone.
        R("card_number", @"(?<![0-9:/=_.#\p{L}])[2-6](?:[ \-]?[0-9]){12,18}(?![0-9\p{L}])",
          v: (value, _, _) =>
          {
              var digits = new string(value.Where(char.IsAsciiDigit).ToArray());
              return digits.Length is >= 13 and <= 19 && Luhn(digits);
          }),
        R("otp", @"(?<![0-9\p{L}])(?<![0-9][\-:/.,])[0-9]{4,8}(?![0-9\p{L}])(?![\-:/.,][0-9])",
          v: (value, m, whole) =>
          {
              if (value.Length == 4 && int.TryParse(value, out var y) && y is >= 1900 and <= 2099) return false;
              int start = Math.Max(0, m.Index - OtpContextBefore);
              int end = Math.Min(whole.Length, m.Index + m.Length + OtpContextAfter);
              return OtpContext.IsMatch(whole.Substring(start, end - start));
          }),
    };

    // ---------------------------------------------------------------- Layer 5

    static readonly Regex EntropyCandidate = new(@"[^\s:=&?,;]{24,}", Base);
    static readonly Regex UrlInText = new(@"(?:\b[a-z][a-z0-9+.\-]*://|\bwww\.)[^\s""'<>]+", CI);
    static readonly Regex SchemePrefix = new(@"^[A-Za-z][A-Za-z0-9+.\-]*://", Base);
    static readonly Regex BareDomain = new(@"^(?:www\.)?[a-z0-9\-]+(?:\.[a-z0-9\-]+)*\.[a-z]{2,}(?:[/?#].*)?$", Base);
    static readonly Regex Email = new(@"^[^@\s]+@[^@\s]+\.[A-Za-z]{2,}$", Base);
    static readonly Regex HexOnly = new(@"^[0-9a-fA-F]{7,128}$", Base);
    static readonly Regex Uuid = new(@"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$", Base);
    static readonly Regex PrefixedId = new(@"^[a-z]{2,10}(?:_[a-z]{2,8})?_[A-Za-z0-9]{8,}$", Base);
    static readonly Regex WindowsPath = new(@"^(?:[A-Za-z]:\\|\\\\)", Base);
    const string TrimChars = "\"'`()<>[]{},;.:!?";
    public const double EntropyThreshold = 4.0;

    public static double ShannonEntropy(string s)
    {
        if (s.Length == 0) return 0;
        // Count by extended grapheme like Swift's Character; for these tokens
        // (no combining marks) code units are equivalent.
        var counts = new Dictionary<char, int>();
        foreach (var c in s) counts[c] = counts.GetValueOrDefault(c) + 1;
        double n = s.Length, h = 0;
        foreach (var v in counts.Values) { var p = v / n; h -= p * Math.Log2(p); }
        return h;
    }

    public static bool LooksLikeHighEntropySecret(string token)
    {
        if (token.Length < 24 || token.Contains(Marker)) return false;
        if (SchemePrefix.IsMatch(token) || BareDomain.IsMatch(token) || Email.IsMatch(token)) return false;
        if (token.StartsWith('/') || token.StartsWith("~/") || token.StartsWith("./") || token.StartsWith("../")
            || WindowsPath.IsMatch(token)) return false;
        if (HexOnly.IsMatch(token) || Uuid.IsMatch(token) || PrefixedId.IsMatch(token)) return false;
        int letters = token.Count(char.IsLetter), digits = token.Count(char.IsDigit);
        if (letters == 0 || digits == 0) return false;
        if (ShannonEntropy(token) <= EntropyThreshold) return false;
        double digitShare = (double)digits / token.Length;
        return ClassSwitchRatio(token) >= 0.35 || digitShare >= 0.2;
    }

    static double ClassSwitchRatio(string s)
    {
        static int Cls(char c) => char.IsUpper(c) ? 0 : char.IsLower(c) ? 1 : char.IsDigit(c) ? 2 : 3;
        if (s.Length < 2) return 0;
        int switches = 0;
        for (int i = 1; i < s.Length; i++) if (Cls(s[i]) != Cls(s[i - 1])) switches++;
        return (double)switches / (s.Length - 1);
    }

    // ---------------------------------------------------------------- checks

    public static bool Luhn(string digits)
    {
        if (digits.Length < 2 || !digits.All(char.IsAsciiDigit)) return false;
        int sum = 0;
        for (int i = 0; i < digits.Length; i++)
        {
            int d = digits[digits.Length - 1 - i] - '0';
            if (i % 2 == 1) { d *= 2; if (d > 9) d -= 9; }
            sum += d;
        }
        return sum % 10 == 0;
    }

    /// <summary>Swedish personnummer / samordningsnummer.</summary>
    public static bool IsPersonnummer(string value)
    {
        var digits = new string(value.Where(char.IsAsciiDigit).ToArray());
        if (digits.Length is not (10 or 12)) return false;
        var ten = digits[^10..];
        int month = (ten[2] - '0') * 10 + (ten[3] - '0');
        int day = (ten[4] - '0') * 10 + (ten[5] - '0');
        if (month is < 1 or > 12) return false;
        if (!(day is >= 1 and <= 31 || day is >= 61 and <= 91)) return false;
        return Luhn(ten);
    }

    // ---------------------------------------------------------------- main

    public static RedactionOutput Redact(string input)
    {
        if (string.IsNullOrEmpty(input)) return new(input ?? "", 0, Array.Empty<string>());
        var text = input;
        var kinds = new List<string>();

        foreach (var rule in Rules)
        {
            var matches = rule.Regex.Matches(text);
            if (matches.Count == 0) continue;
            var sb = new StringBuilder(text);
            for (int i = matches.Count - 1; i >= 0; i--)
            {
                var m = matches[i];
                var g = m.Groups[rule.Group];
                if (!g.Success || g.Length == 0) continue;
                var value = g.Value;
                if (value.StartsWith(Marker)) continue;
                if (rule.Validate != null && !rule.Validate(value, m, text)) continue;
                sb.Remove(g.Index, g.Length).Insert(g.Index, $"{Marker}{rule.Kind}]");
                kinds.Add(rule.Kind);
            }
            text = sb.ToString();
        }

        var found = EntropyCandidate.Matches(text);
        if (found.Count > 0)
        {
            var urls = UrlInText.Matches(text).Select(u => (u.Index, End: u.Index + u.Length)).ToList();
            var sb = new StringBuilder(text);
            for (int i = found.Count - 1; i >= 0; i--)
            {
                var m = found[i];
                int mEnd = m.Index + m.Length;
                if (urls.Any(u => u.Index < mEnd && m.Index < u.End)) continue;
                var raw = m.Value;
                if (raw.Contains(Marker)) continue;
                int lo = 0, hi = raw.Length;
                while (lo < hi && TrimChars.Contains(raw[lo])) lo++;
                while (hi > lo && TrimChars.Contains(raw[hi - 1])) hi--;
                if (hi - lo < 24) continue;
                var token = raw[lo..hi];
                if (LooksLikeHighEntropySecret(token))
                {
                    sb.Remove(m.Index + lo, hi - lo).Insert(m.Index + lo, $"{Marker}high_entropy]");
                    kinds.Add("high_entropy");
                }
            }
            text = sb.ToString();
        }
        return new(text, kinds.Count, kinds);
    }
}
