using FlaUI.Core;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.UIA3;
using DayLog.Core;

namespace DayLog.Win;

/// <summary>
/// Reads window content through UI Automation (the Windows counterpart of
/// macOS's Accessibility API). One instance, used only from the recorder thread.
///
/// Chromium turns its accessibility tree on automatically when a UIA client
/// queries it, so no AXEnhancedUserInterface-style flag is needed here; the
/// trade-off is a short delay the first time a Chrome/Edge window is read.
/// </summary>
internal sealed class UiaReader : IDisposable
{
    readonly UIA3Automation _automation = new();

    public void Dispose() => _automation.Dispose();

    internal sealed class Snapshot { public string Text = ""; public bool Truncated; }

    internal static readonly HashSet<string> BrowserExes = new(StringComparer.OrdinalIgnoreCase)
    { "chrome.exe", "msedge.exe", "brave.exe", "vivaldi.exe", "opera.exe", "arc.exe", "firefox.exe" };

    static readonly HashSet<ControlType> TextInputTypes = new()
    { ControlType.Edit, ControlType.ComboBox, ControlType.Document };
    static readonly HashSet<ControlType> LabelledTypes = new()
    { ControlType.Button, ControlType.MenuItem, ControlType.CheckBox, ControlType.RadioButton,
      ControlType.TabItem, ControlType.Hyperlink, ControlType.ListItem, ControlType.TreeItem, ControlType.SplitButton };

    public AutomationElement? ForegroundWindow(IntPtr hwnd)
    {
        try { return hwnd == IntPtr.Zero ? null : _automation.FromHandle(hwnd); }
        catch { return null; }
    }

    public AutomationElement? FocusedElementOrNull()
    {
        try { return _automation.FocusedElement(); }
        catch { return null; }
    }

    // ---- safe property helpers (UIA throws on stale / disappearing elements)

    static string? Name(AutomationElement e) { try { return e.Properties.Name.ValueOrDefault; } catch { return null; } }
    static string? ClassName(AutomationElement e) { try { return e.Properties.ClassName.ValueOrDefault; } catch { return null; } }
    static string? AutomationId(AutomationElement e) { try { return e.Properties.AutomationId.ValueOrDefault; } catch { return null; } }
    static string? HelpText(AutomationElement e) { try { return e.Properties.HelpText.ValueOrDefault; } catch { return null; } }
    static ControlType CtrlType(AutomationElement e) { try { return e.Properties.ControlType.ValueOrDefault; } catch { return ControlType.Custom; } }
    static bool IsPassword(AutomationElement e) { try { return e.Properties.IsPassword.ValueOrDefault; } catch { return false; } }

    static string? ValueText(AutomationElement e)
    {
        try { var p = e.Patterns.Value.PatternOrDefault; return p?.Value?.ValueOrDefault; }
        catch { return null; }
    }

    static AutomationElement[] Children(AutomationElement e)
    {
        try { return e.FindAllChildren(); } catch { return Array.Empty<AutomationElement>(); }
    }

    /// <summary>True if the focused element must never be read.</summary>
    public static bool IsSensitive(AutomationElement e, ControlType type)
    {
        if (IsPassword(e)) return true;
        bool isInput = TextInputTypes.Contains(type);
        if (!isInput) return false;
        return Redactor.IsSensitiveField(false, new[] { Name(e), AutomationId(e), ClassName(e), HelpText(e) });
    }

    /// <summary>Walks the window tree (iterative, budgeted) and collects text.</summary>
    public Snapshot WindowText(AutomationElement root, double timeBudgetSec = 3, int nodeBudget = 60_000)
    {
        var lines = new List<string>();
        int visited = 0;
        var deadline = DateTime.UtcNow.AddSeconds(timeBudgetSec);
        bool truncated = false;
        string? last = null;

        void Add(string? s)
        {
            if (string.IsNullOrWhiteSpace(s)) return;
            s = s.Trim();
            if (s.Length > 200_000) s = s[..200_000];
            if (s != last) { lines.Add(s); last = s; }
        }

        var stack = new Stack<AutomationElement>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            var el = stack.Pop();
            if (++visited > nodeBudget || (visited % 200 == 0 && DateTime.UtcNow > deadline)) { truncated = true; break; }

            var type = CtrlType(el);
            if (IsPassword(el)) continue;   // never descend into a password field

            if (type == ControlType.Text) Add(Name(el) ?? ValueText(el));
            else if (TextInputTypes.Contains(type))
            {
                if (!IsSensitive(el, type)) Add(ValueText(el) ?? Name(el));
            }
            else if (type == ControlType.Image) { /* skip */ }
            else if (LabelledTypes.Contains(type)) Add(Name(el));

            var kids = Children(el);
            for (int i = kids.Length - 1; i >= 0; i--) stack.Push(kids[i]);
        }
        return new Snapshot { Text = string.Join("\n", lines), Truncated = truncated };
    }

    /// <summary>Current page URL for a Chromium window: the document's value,
    /// falling back to the address bar edit. Firefox exposes neither reliably.</summary>
    public string? BrowserUrl(AutomationElement window)
    {
        var doc = FindFirst(window, ControlType.Document, maxDepth: 14);
        if (doc != null)
        {
            var v = ValueText(doc);
            if (!string.IsNullOrEmpty(v) && !v.StartsWith("about:")) return v;
        }
        // Address bar: an Edit whose name mentions address/search.
        var bar = FindFirst(window, ControlType.Edit, maxDepth: 10, predicate: e =>
        {
            var n = (Name(e) ?? "").ToLowerInvariant();
            return n.Contains("address") || n.Contains("adress") || n.Contains("search or type")
                   || n.Contains("sök eller ange");
        });
        if (bar != null)
        {
            var v = ValueText(bar);
            if (!string.IsNullOrWhiteSpace(v)) return v;
        }
        return null;
    }

    AutomationElement? FindFirst(AutomationElement root, ControlType type, int maxDepth,
                                 Func<AutomationElement, bool>? predicate = null)
    {
        var level = new List<AutomationElement> { root };
        for (int depth = 0; depth < maxDepth && level.Count > 0; depth++)
        {
            var next = new List<AutomationElement>();
            foreach (var el in level)
            {
                if (CtrlType(el) == type && (predicate == null || predicate(el))) return el;
                next.AddRange(Children(el));
                if (next.Count > 4000) break;   // keep the breadth search bounded
            }
            level = next;
        }
        return null;
    }
}
