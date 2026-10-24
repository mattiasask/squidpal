using System.Collections.Concurrent;
using System.Diagnostics;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using DayLog.Core;

namespace DayLog.Win;

/// <summary>What the UI thread observed this tick and hands to the recorder.</summary>
internal sealed class TickInput
{
    public bool Active;
    public IntPtr Hwnd;
    public string? ClipboardText;           // already filtered for concealed formats on the UI thread
    public DateTime? ScrolledAt;
}

internal readonly record struct DayStats(string Day, int Entries, int Redactions, long Bytes);

/// <summary>
/// Port of macOS Recorder.swift. All UIA reads and file writes run on one
/// dedicated STA-free (MTA) thread via <see cref="_queue"/>, so the mutable
/// state below needs no locking.
/// </summary>
internal sealed class Recorder : IDisposable
{
    readonly BlockingCollection<Action> _queue = new();
    readonly Thread _thread;
    readonly UiaReader _uia = new();

    public LogWriter? Writer;
    public Action<DayStats>? OnStats;
    public Action<string>? OnError;

    public Recorder()
    {
        _thread = new Thread(Loop) { IsBackground = true, Name = "daylog.recorder" };
        _thread.SetApartmentState(ApartmentState.MTA);
        _thread.Start();
    }

    public void Enqueue(Action a) { try { _queue.Add(a); } catch { } }
    void Loop() { foreach (var a in _queue.GetConsumingEnumerable()) { try { a(); } catch (Exception e) { OnError?.Invoke(e.Message); } } }

    public void Dispose() { _queue.CompleteAdding(); _uia.Dispose(); }

    // ---- state (recorder thread only)

    sealed record Context(int Pid, string? App, string? Exe, string? WindowTitle, string? Url, string? PageTitle)
    {
        public string Key => $"{Exe}|{WindowTitle}|{Url}";
    }

    Context? _current;
    DateTime _currentSince = DateTime.UtcNow;
    string? _lastTextHash;
    DateTime _lastTextCheck = DateTime.MinValue;
    DateTime? _lastScrollHandled;

    AutomationElement? _focusedField;
    string? _fieldValue;
    DateTime _fieldChangedAt = DateTime.MinValue;
    bool _fieldPending;
    string? _lastTypingHash;

    string? _selectionCandidate;
    string? _lastSelection;

    readonly LineDedup _dedup = new();
    DayStats _stats = new(LogWriter.DayString(), 0, 0, 0);

    static readonly System.Text.RegularExpressions.Regex DayFileName =
        new(@"\d{4}-\d{2}-\d{2}(?:-\d+)?\.jsonl", System.Text.RegularExpressions.RegexOptions.Compiled);

    // ---- public ops (enqueue from UI thread)

    public void LoadStats()
    {
        var day = LogWriter.DayString();
        var (e, r) = Settings.LoadCounters(day);
        _dedup.Reset();
        _stats = new DayStats(day, e, r, TodayBytes());
        OnStats?.Invoke(_stats);
    }

    public void Tick(TickInput input)
    {
        var now = DateTime.UtcNow;
        if (_stats.Day != LogWriter.DayString()) LoadStats();

        if (!input.Active) { CloseCurrent(now); return; }

        uint pid = 0;
        if (input.Hwnd != IntPtr.Zero) Native.GetWindowThreadProcessId(input.Hwnd, out pid);
        if (pid == 0) { CloseCurrent(now); return; }
        if (pid == Environment.ProcessId) return;

        string? exe = null, appName = null;
        try
        {
            using var p = Process.GetProcessById((int)pid);
            exe = SafeProcessFileName(p);
            appName = string.IsNullOrEmpty(p.MainWindowTitle) ? exe : p.ProcessName;
        }
        catch { }

        bool blocked = Redactor.IsBlockedApp(exe, appName);

        var win = blocked ? null : _uia.ForegroundWindow(input.Hwnd);
        string? title = Native.WindowTitle(input.Hwnd);
        string? url = null, pageTitle = null;
        if (!blocked && win != null && exe != null && UiaReader.BrowserExes.Contains(exe))
        {
            url = _uia.BrowserUrl(win);
            pageTitle = title;
        }
        var ctx = new Context((int)pid, appName, exe, title, url, pageTitle);

        bool selfView = !blocked && IsLogView(ctx);
        bool textless = blocked || selfView;

        // 1. Context switch -> leave + focus
        if (_current?.Key != ctx.Key)
        {
            CloseCurrent(now);
            _current = ctx;
            _currentSince = now;
            string? text = null;
            if (!textless && win != null)
            {
                var snap = _uia.WindowText(win);
                text = _dedup.NewLines(snap.Text, ctx.Exe);
                _lastTextHash = Hash(snap.Text);
            }
            else _lastTextHash = null;
            _lastTextCheck = now;
            Emit("focus", ctx, text, blocked);
            ResetField();
        }
        else if (!textless && win != null)
        {
            bool scrollDue = input.ScrolledAt is { } s && (now - s.ToUniversalTime()).TotalSeconds >= 1 && _lastScrollHandled != s;
            if (scrollDue || (now - _lastTextCheck).TotalSeconds >= 10)
            {
                var snap = _uia.WindowText(win);
                var h = Hash(snap.Text);
                if (h != _lastTextHash)
                {
                    var added = _dedup.NewLines(snap.Text, ctx.Exe);
                    if (added != null) Emit(scrollDue ? "scroll" : "update", ctx, added, false);
                    _lastTextHash = h;
                }
                _lastTextCheck = now;
                if (scrollDue) _lastScrollHandled = input.ScrolledAt;
            }
        }

        // 2. Typing + selection in the focused element
        if (!textless) TrackFocusedField(ctx, now);
        else ResetField();

        // 3. Clipboard (already filtered on the UI thread)
        if (!textless && input.ClipboardText is { } clip && !LineDedup.LooksLikeOwnLog(clip))
            Emit("clipboard", ctx, clip, false);
    }

    public void PauseOrStop() => CloseCurrent(DateTime.UtcNow);

    public void DeleteToday()
    {
        if (Writer == null) return;
        var day = LogWriter.DayString();
        foreach (var f in LogWriter.DayFiles(Writer.Folder, day)) { try { File.Delete(f); } catch { } }
        Settings.ClearCounters(day);
        _current = null; _lastTextHash = null; _lastTypingHash = null; _lastSelection = null;
        _dedup.Reset();
        LoadStats();
    }

    public string? TodayFile()
    {
        if (Writer == null) return null;
        var files = LogWriter.DayFiles(Writer.Folder, LogWriter.DayString());
        return files.Count == 0 ? null : files[^1];
    }

    // ---- internals

    void CloseCurrent(DateTime now)
    {
        FlushTyping(force: true);
        if (_current is not { } c) return;
        bool blocked = Redactor.IsBlockedApp(c.Exe, c.App);
        Emit("leave", c, null, blocked, dwell: (now - _currentSince).TotalSeconds);
        _current = null;
        _lastTextHash = null;
    }

    void ResetField() { _focusedField = null; _fieldValue = null; _fieldPending = false; _selectionCandidate = null; }

    void TrackFocusedField(Context ctx, DateTime now)
    {
        AutomationElement? el;
        try { el = _uia.FocusedElementOrNull(); } catch { return; }
        if (el == null) return;

        ControlType type;
        try { type = el.Properties.ControlType.ValueOrDefault; } catch { return; }

        if (UiaReader.IsSensitive(el, type)) { FlushTyping(true); ResetField(); return; }

        bool isInput = type is ControlType.Edit or ControlType.ComboBox or ControlType.Document;
        string? value = null;
        try { value = el.Patterns.Value.PatternOrDefault?.Value?.ValueOrDefault; } catch { }

        if (_focusedField != null && !Equals(SafeRuntimeId(_focusedField), SafeRuntimeId(el)))
        { FlushTyping(true); ResetField(); }
        if (_focusedField == null) { _focusedField = el; _fieldValue = value; }

        if (isInput && value != null && value != _fieldValue)
        { _fieldValue = value; _fieldChangedAt = now; _fieldPending = true; }
        if (_fieldPending && (now - _fieldChangedAt).TotalSeconds >= 2) FlushTyping(false);

        // Selection: write once stable for a tick.
        string? sel = null;
        try { sel = el.Patterns.Text.PatternOrDefault?.GetSelection()?.FirstOrDefault()?.GetText(100_000)?.Trim(); } catch { }
        if (!string.IsNullOrEmpty(sel))
        {
            if (sel == _selectionCandidate && sel != _lastSelection) { Emit("selection", ctx, sel, false); _lastSelection = sel; }
            _selectionCandidate = sel;
        }
        else _selectionCandidate = null;
    }

    void FlushTyping(bool force)
    {
        if (!_fieldPending || _current is not { } c || _fieldValue is not { } value) return;
        _fieldPending = false;
        var h = Hash(value);
        if (h == _lastTypingHash || string.IsNullOrWhiteSpace(value)) return;
        _lastTypingHash = h;
        var added = _dedup.NewLines(value, c.Exe);
        if (added != null) Emit("typing", c, added, false);
    }

    void Emit(string ev, Context c, string? text, bool blocked, double? dwell = null)
    {
        if (Writer == null) return;
        var e = new LogEvent { Event = ev, App = c.App, BundleId = c.Exe, DwellSeconds = dwell };
        int n = 0;
        string? Clean(string? s)
        {
            if (string.IsNullOrEmpty(s)) return null;
            var r = Redactor.Redact(s);
            n += r.Count;
            foreach (var k in r.Kinds) e.RedactionKinds[k] = e.RedactionKinds.GetValueOrDefault(k) + 1;
            return r.Text;
        }
        if (!blocked)
        {
            e.WindowTitle = Clean(c.WindowTitle);
            e.Url = Clean(c.Url);
            e.PageTitle = Clean(c.PageTitle);
            e.Text = Clean(text);
        }
        e.Redactions = n;
        try
        {
            int bytes = Writer.Append(e);
            _stats = _stats with { Entries = _stats.Entries + 1, Redactions = _stats.Redactions + n, Bytes = _stats.Bytes + bytes };
            Settings.SaveCounters(_stats.Day, _stats.Entries, _stats.Redactions);
            OnStats?.Invoke(_stats);
        }
        catch (Exception ex) { OnError?.Invoke("Kunde inte skriva: " + ex.Message); }
    }

    bool IsLogView(Context c)
    {
        foreach (var s in new[] { c.WindowTitle, c.PageTitle, c.Url })
            if (s != null && DayFileName.IsMatch(s)) return true;
        return false;
    }

    long TodayBytes()
    {
        if (Writer == null) return 0;
        return LogWriter.DayFiles(Writer.Folder, LogWriter.DayString()).Sum(LogWriter.Size);
    }

    static string Hash(string s)
    {
        var bytes = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(s));
        return Convert.ToHexString(bytes);
    }

    static string? SafeProcessFileName(Process p)
    {
        try { return Path.GetFileName(p.MainModule?.FileName) ?? p.ProcessName + ".exe"; }
        catch { return p.ProcessName + ".exe"; }
    }

    static string SafeRuntimeId(AutomationElement e)
    {
        try { return string.Join(",", e.Properties.RuntimeId.ValueOrDefault ?? Array.Empty<int>()); }
        catch { return ""; }
    }
}
