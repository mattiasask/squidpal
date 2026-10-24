using System.Runtime.InteropServices;
using Microsoft.Win32;
using DayLog.Core;

namespace DayLog.Win;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        ApplicationConfiguration.Initialize();
        using var ctx = new TrayAppContext();
        Application.Run(ctx);
    }
}

/// <summary>No main window; everything hangs off the tray icon.</summary>
internal sealed class TrayAppContext : ApplicationContext
{
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();

    enum PauseMode { None, Until, Indefinite }

    readonly NotifyIcon _tray = new();
    readonly System.Windows.Forms.Timer _timer = new() { Interval = 1000 };
    readonly Recorder _recorder = new();
    // Hidden control with a real window handle, used to marshal recorder-thread
    // callbacks onto the UI thread (NotifyIcon/ContextMenuStrip have no handle
    // until shown, so they can't be the marshal target during startup).
    readonly Control _sync = new();

    string? _folder;
    PauseMode _pauseMode = PauseMode.None;
    DateTime _pauseUntil;
    bool _locked;
    uint _clipboardSeq;
    DateTime? _scrolledAt;
    DayStats _stats = new(LogWriter.DayString(), 0, 0, 0);
    string? _lastError;
    TrayIcon.State _iconState = TrayIcon.State.Warning;
    bool _iconLight;
    Icon? _currentIcon;

    bool IsPaused => _pauseMode switch
    {
        PauseMode.Indefinite => true,
        PauseMode.Until => _pauseUntil > DateTime.Now,
        _ => false,
    };
    bool IsRecording => _folder != null && !IsPaused && !_locked;

    public TrayAppContext()
    {
        _sync.CreateControl();   // force a window handle for cross-thread marshaling

        _recorder.OnStats = s => TryOnUi(() => { _stats = s; UpdateMenu(); });
        _recorder.OnError = m => TryOnUi(() => { _lastError = m; UpdateMenu(); });

        _tray.Visible = true;
        _tray.ContextMenuStrip = new ContextMenuStrip();
        _tray.ContextMenuStrip.Opening += (_, _) => BuildMenu();

        _folder = Settings.Folder;
        if (_folder != null && Directory.Exists(_folder)) StartWriter(_folder);
        else ChooseFolder();

        _clipboardSeq = GetClipboardSequenceNumber();
        SystemEvents.SessionSwitch += OnSessionSwitch;
        Application.ApplicationExit += (_, _) => Cleanup();

        _timer.Tick += (_, _) => Tick();
        _timer.Start();
        RefreshIcon(force: true);
    }

    void OnSessionSwitch(object? s, SessionSwitchEventArgs e)
    {
        if (e.Reason is SessionSwitchReason.SessionLock or SessionSwitchReason.SessionLogoff) _locked = true;
        else if (e.Reason is SessionSwitchReason.SessionUnlock or SessionSwitchReason.SessionLogon) _locked = false;
    }

    void Tick()
    {
        if (_pauseMode == PauseMode.Until && _pauseUntil <= DateTime.Now) _pauseMode = PauseMode.None;

        var input = new TickInput { Active = IsRecording, Hwnd = Native.GetForegroundWindow(), ScrolledAt = _scrolledAt };

        // Clipboard: always advance the marker so nothing copied while paused is
        // written later. Only read text when actively recording and allowed.
        uint seq = GetClipboardSequenceNumber();
        if (seq != _clipboardSeq)
        {
            _clipboardSeq = seq;
            if (IsRecording) input.ClipboardText = ReadClipboardIfAllowed();
        }

        var captured = input;
        _recorder.Enqueue(() => _recorder.Tick(captured));
        RefreshIcon();
    }

    string? ReadClipboardIfAllowed()
    {
        try
        {
            var data = Clipboard.GetDataObject();
            if (data == null) return null;
            var formats = data.GetFormats(false) ?? Array.Empty<string>();
            if (Redactor.IsConcealedClipboard(formats)) return null;
            return Clipboard.ContainsText() ? Clipboard.GetText() : null;
        }
        catch { return null; }   // clipboard can be locked by another app
    }

    // ---- writer / folder

    void StartWriter(string folder)
    {
        _folder = folder;
        _recorder.Enqueue(() =>
        {
            _recorder.PauseOrStop();
            _recorder.Writer = new LogWriter(folder);
            _recorder.LoadStats();
        });
    }

    void ChooseFolder()
    {
        using var dlg = new FolderBrowserDialog
        {
            Description = "Välj mapp där Squidpal sparar dagsfilerna (ÅÅÅÅ-MM-DD.jsonl). " +
                          "Välj en synkad mapp om du vill ha dem i OneDrive/Drive/Dropbox.",
            UseDescriptionForTitle = true,
            ShowNewFolderButton = true,
        };
        if (dlg.ShowDialog() == DialogResult.OK && Directory.Exists(dlg.SelectedPath))
        {
            Settings.Folder = dlg.SelectedPath;
            StartWriter(dlg.SelectedPath);
        }
    }

    // ---- menu

    void BuildMenu()
    {
        var m = _tray.ContextMenuStrip!;
        m.Items.Clear();

        m.Items.Add(new ToolStripMenuItem(StatusLine()) { Enabled = false });
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add(new ToolStripMenuItem(
            $"Idag: {_stats.Entries} poster · {_stats.Redactions} maskeringar") { Enabled = false });
        m.Items.Add(new ToolStripMenuItem(
            "Filstorlek: " + BytesText(_stats.Bytes)) { Enabled = false });
        if (_lastError != null) m.Items.Add(new ToolStripMenuItem(_lastError) { Enabled = false });
        m.Items.Add(new ToolStripSeparator());

        if (IsPaused)
            m.Items.Add(new ToolStripMenuItem("Slå på inspelning", null, (_, _) => { _pauseMode = PauseMode.None; RefreshIcon(); }));
        else
        {
            var pause = new ToolStripMenuItem("Pausa");
            pause.DropDownItems.Add(new ToolStripMenuItem("15 minuter", null, (_, _) => PauseFor(15)));
            pause.DropDownItems.Add(new ToolStripMenuItem("1 timme", null, (_, _) => PauseFor(60)));
            pause.DropDownItems.Add(new ToolStripMenuItem("Tills jag slår på igen", null, (_, _) => PauseIndef()));
            m.Items.Add(pause);
        }
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add(new ToolStripMenuItem("Öppna dagens fil", null, (_, _) => OpenToday()));
        m.Items.Add(new ToolStripMenuItem("Visa mappen", null, (_, _) => RevealFolder()));
        m.Items.Add(new ToolStripMenuItem("Radera dagens fil…", null, (_, _) => DeleteToday()));
        m.Items.Add(new ToolStripMenuItem(_folder == null ? "Välj mapp…" : "Byt mapp…", null, (_, _) => ChooseFolder()));
        if (_folder != null) m.Items.Add(new ToolStripMenuItem(_folder) { Enabled = false });
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add(new ToolStripMenuItem("Avsluta Squidpal", null, (_, _) => ExitApp()));
    }

    void UpdateMenu() { if (_tray.ContextMenuStrip!.Visible) BuildMenu(); }

    string StatusLine()
    {
        if (_folder == null) return "⚠ Ingen mapp vald – spelar inte in";
        if (_locked) return "Skärmen är låst – spelar inte in";
        return _pauseMode switch
        {
            PauseMode.Indefinite => "⏸ Pausad tills du slår på igen",
            PauseMode.Until when _pauseUntil > DateTime.Now => $"⏸ Pausad till {_pauseUntil:HH:mm}",
            _ => "● Spelar in",
        };
    }

    void PauseFor(int minutes) { _pauseMode = PauseMode.Until; _pauseUntil = DateTime.Now.AddMinutes(minutes); _recorder.Enqueue(_recorder.PauseOrStop); RefreshIcon(); }
    void PauseIndef() { _pauseMode = PauseMode.Indefinite; _recorder.Enqueue(_recorder.PauseOrStop); RefreshIcon(); }

    void OpenToday()
    {
        if (_folder == null) return;
        var files = LogWriter.DayFiles(_folder, LogWriter.DayString());
        if (files.Count == 0) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(files[^1]) { UseShellExecute = true }); } catch { }
    }

    void RevealFolder()
    {
        if (_folder == null) return;
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(_folder) { UseShellExecute = true }); } catch { }
    }

    void DeleteToday()
    {
        if (MessageBox.Show("Alla poster från idag tas bort permanent från mappen.", "Radera dagens fil?",
            MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK)
            _recorder.Enqueue(_recorder.DeleteToday);
    }

    // ---- icon

    void RefreshIcon(bool force = false)
    {
        var state = IsRecording ? TrayIcon.State.Recording
                  : _folder == null ? TrayIcon.State.Warning
                  : TrayIcon.State.Paused;
        bool light = TrayIcon.IsLightTaskbar();
        if (!force && state == _iconState && light == _iconLight && _currentIcon != null) return;
        _iconState = state;
        _iconLight = light;

        Icon icon;
        try { icon = TrayIcon.Load(state); }
        catch { return; }   // tray assets missing; keep the current icon
        var old = _currentIcon;
        _currentIcon = icon;
        _tray.Icon = icon;
        _tray.Text = state switch
        {
            TrayIcon.State.Recording => "Squidpal – spelar in",
            TrayIcon.State.Paused => "Squidpal – pausad",
            _ => "Squidpal – ingen mapp vald",
        };
        old?.Dispose();
    }


    void TryOnUi(Action a)
    {
        try
        {
            if (_sync.IsHandleCreated && _sync.InvokeRequired) _sync.BeginInvoke(a);
            else a();
        }
        catch { }
    }

    void ExitApp() { Cleanup(); ExitThread(); }

    bool _cleaned;
    void Cleanup()
    {
        if (_cleaned) return; _cleaned = true;
        _timer.Stop();
        SystemEvents.SessionSwitch -= OnSessionSwitch;
        _recorder.Enqueue(_recorder.PauseOrStop);
        try { Thread.Sleep(150); } catch { }
        _recorder.Dispose();
        _tray.Visible = false;
        _tray.Dispose();
        _sync.Dispose();
        _currentIcon?.Dispose();
    }

    static string BytesText(long b)
    {
        string[] u = { "B", "KB", "MB", "GB" };
        double v = b; int i = 0;
        while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
        return $"{v:0.#} {u[i]}";
    }
}
