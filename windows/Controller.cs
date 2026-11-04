using System.Media;

namespace ProsperityVoice;

/// <summary>Runs one dictation at a time: record → transcribe → clean → save → paste.</summary>
public sealed class Controller
{
    public enum Phase { Idle, Recording, Processing }

    public Phase Current { get; private set; } = Phase.Idle;
    public event Action? PhaseChanged;

    readonly HistoryStore history;
    readonly RecordingPanel panel;
    public Hotkey Hotkey { get; }
    Recorder recorder = new();
    /// <summary>Changes whenever a session ends, so stale results can never paste.</summary>
    Guid session = Guid.NewGuid();
    DateTime startedAt;
    string? targetApp;

    public Controller(HistoryStore history, RecordingPanel panel, Hotkey hotkey)
    {
        this.history = history;
        this.panel = panel;
        Hotkey = hotkey;
        panel.FinishClicked += Finish;
        panel.CancelClicked += () => Cancel(quiet: false);
        hotkey.OnAction += Handle;
        hotkey.OnPolish += () => _ = PolishSelection();
    }

    void SetPhase(Phase p)
    {
        Current = p;
        PhaseChanged?.Invoke();
    }

    public void Handle(GestureAction action)
    {
        switch (action)
        {
            case GestureAction.Start: Start(false); break;
            case GestureAction.Latch: if (Current == Phase.Recording) panel.SetHandsFree(); break;
            case GestureAction.Finish: Finish(); break;
            case GestureAction.Cancel: Cancel(quiet: true); break;
        }
    }

    /// <summary>Start/stop from the tray menu.</summary>
    public void Toggle()
    {
        if (Current == Phase.Idle) Start(true);
        else if (Current == Phase.Recording) Finish();
    }

    public void Start(bool handsFree)
    {
        if (Current != Phase.Idle)
        {
            if (Current == Phase.Processing) Hotkey.ResetGesture();
            return;
        }
        if (!Recorder.HasMicrophone)
        {
            Hotkey.ResetGesture();
            panel.Flash("No microphone found", good: false, seconds: 3);
            return;
        }
        if (!Whisperer.ModelReady)
        {
            Hotkey.ResetGesture();
            panel.Flash("Speech model still downloading. Try again in a minute.", good: false, seconds: 3);
            return;
        }
        session = Guid.NewGuid();
        startedAt = DateTime.Now;
        targetApp = Inserter.ForegroundProcessName();
        var token = session;
        recorder = new Recorder();
        recorder.Level += level => panel.BeginInvoke(() => { if (session == token) panel.PushLevel(level); });
        try
        {
            recorder.Start(Settings.Current.Words);
        }
        catch (Exception e)
        {
            Hotkey.ResetGesture();
            Fail($"Couldn't start the microphone: {e.Message}");
            return;
        }
        SetPhase(Phase.Recording);
        Log.Write($"start app={targetApp ?? "-"} engine={Settings.Current.CleanupEngine}");
        panel.ShowRecording(handsFree);
        Sound(SystemSounds.Asterisk);
    }

    public async void Finish()
    {
        if (Current != Phase.Recording) return;
        Hotkey.ResetGesture();
        SetPhase(Phase.Processing);
        panel.ShowWorking("Transcribing…");
        var token = session;
        var seconds = (DateTime.Now - startedAt).TotalSeconds;
        var rec = recorder;
        try
        {
            var raw = await rec.Stop();
            KeepRecording();
            if (token != session) return;
            await Deliver(raw, seconds, token);
        }
        catch (Exception e)
        {
            KeepRecording();
            Log.Write($"transcription error: {e.Message}");
            if (token != session) return;
            Fail("Transcription failed. Use Retry last recording in the tray menu.");
        }
    }

    public void Cancel(bool quiet)
    {
        switch (Current)
        {
            case Phase.Recording:
                Log.Write("cancel while recording");
                recorder.Cancel();
                KeepRecording();
                session = Guid.NewGuid();
                SetPhase(Phase.Idle);
                Hotkey.ResetGesture();
                // A quick accidental tap just disappears; a real cancel says so.
                if (quiet && (DateTime.Now - startedAt).TotalSeconds < 1) panel.HidePanel();
                else panel.Flash("Cancelled", good: false, seconds: 1);
                break;
            case Phase.Processing:
                session = Guid.NewGuid();
                SetPhase(Phase.Idle);
                panel.Flash("Cancelled (saved in history if transcribed)", good: false, seconds: 1.5);
                break;
        }
    }

    /// <summary>Re-transcribe the last recording (after a failure, cancel, or just to redo it).</summary>
    public async void RetryLast()
    {
        if (Current != Phase.Idle || !File.Exists(Paths.LastRecording))
        {
            panel.Flash("No saved recording to retry", good: false);
            return;
        }
        SetPhase(Phase.Processing);
        session = Guid.NewGuid();
        var token = session;
        panel.ShowWorking("Transcribing last recording…");
        try
        {
            var samples = Whisperer.ReadWav(Paths.LastRecording);
            var raw = Whisperer.PeakDb(samples) < Whisperer.SpeechThresholdDb
                ? "" : await Whisperer.Transcribe(samples, Settings.Current.Words);
            if (token != session) return;
            await Deliver(raw, null, token);
        }
        catch (Exception e)
        {
            if (token != session) return;
            Fail($"Retry failed: {e.Message}");
        }
    }

    async Task Deliver(string raw, double? seconds, Guid token)
    {
        if (string.IsNullOrWhiteSpace(raw))
        {
            Fail("Didn't catch any words. Recording kept for Retry.");
            return;
        }
        var settings = Settings.Current;
        // Save what was heard before anything else can go wrong.
        var entry = new HistoryEntry { Kind = "dictation", Original = raw, Text = raw, Engine = "raw", App = targetApp, Seconds = seconds };
        var keep = settings.KeepHistory;
        if (keep) history.Add(entry);

        var engine = settings.CleanupEngine;
        var provider = EngineInfo.ProviderOf(engine);
        if (provider != null) panel.ShowWorking($"Cleaning up with {ProviderInfo.Name(provider.Value)}…");
        var fixedText = Settings.ApplyReplacements(raw, settings.Replacements);
        var result = await Cleaner.CleanDictation(fixedText, engine, settings.Words);
        if (token != session) return;

        var focus = Inserter.DescribeFocus();
        var outcome = await Inserter.Insert(result.Text);
        Log.Write($"deliver words={Cleaner.WordCount(raw)}→{Cleaner.WordCount(result.Text)} engine={result.Engine} note={result.Note ?? "-"} outcome={outcome} focus=[{focus}]");
        if (keep)
            history.Update(entry.Id, e => { e.Text = result.Text; e.Engine = result.Engine; e.Pasted = outcome == Inserter.Outcome.Pasted; });

        SetPhase(Phase.Idle);
        var message = outcome == Inserter.Outcome.Pasted ? "Pasted" : "Copied. Press Ctrl+V to paste.";
        panel.Flash(result.Note == null ? message : $"{message} ({result.Note})", true, outcome == Inserter.Outcome.Pasted ? 1.2 : 2.5);
        Sound(SystemSounds.Beep);
    }

    void Fail(string message)
    {
        Log.Write($"fail: {message}");
        SetPhase(Phase.Idle);
        panel.Flash(message, good: false, seconds: 3.5);
    }

    /// <summary>Move the just-finished recording to last.wav so Retry can use it.</summary>
    static void KeepRecording()
    {
        try
        {
            if (!File.Exists(Paths.CurrentRecording)) return;
            File.Move(Paths.CurrentRecording, Paths.LastRecording, overwrite: true);
        }
        catch { }
    }

    static void Sound(SystemSound s)
    {
        if (Settings.Current.PlaySounds) s.Play();
    }

    // MARK: Polish (Ctrl+Alt+P)

    /// <summary>Copy the selection, polish it, and paste the result over it.</summary>
    public async Task PolishSelection()
    {
        if (Current != Phase.Idle) return;
        var before = Clipboard.ContainsText() ? Clipboard.GetText() : null;
        Clipboard.Clear();
        await Task.Delay(120);              // let Ctrl+Alt be released
        Inserter.CopyShortcut();
        string? selected = null;
        for (var i = 0; i < 10 && string.IsNullOrEmpty(selected); i++)
        {
            await Task.Delay(60);
            if (Clipboard.ContainsText()) selected = Clipboard.GetText();
        }
        if (string.IsNullOrWhiteSpace(selected))
        {
            if (before != null) Inserter.SetClipboard(before);
            panel.Flash("Select some text first, then press Ctrl+Alt+P", good: false, seconds: 2.5);
            return;
        }
        var provider = Settings.Current.PolishEngine;
        SetPhase(Phase.Processing);
        panel.ShowWorking($"Polishing with {ProviderInfo.Name(provider)}…");
        try
        {
            var result = await Cleaner.Polish(selected, provider, Settings.Current.Words);
            Inserter.SetClipboard(result.Text);
            Inserter.PasteShortcut();
            if (Settings.Current.KeepHistory)
                history.Add(new HistoryEntry { Kind = "polish", Original = selected, Text = result.Text, Engine = result.Engine, App = Inserter.ForegroundProcessName(), Pasted = true });
            panel.Flash("Polished");
        }
        catch (Exception e)
        {
            Inserter.SetClipboard(selected);
            panel.Flash($"Polish failed: {e.Message}", good: false, seconds: 3);
        }
        finally { SetPhase(Phase.Idle); }
    }
}
