using Microsoft.Win32;

namespace ProsperityVoice;

/// <summary>History and Settings, in one window opened from the tray icon.</summary>
public sealed class MainForm : Form
{
    readonly HistoryStore history;
    readonly Controller controller;
    readonly TabControl tabs = new() { Dock = DockStyle.Fill };

    // History tab
    readonly TextBox search = new() { PlaceholderText = "Search", Width = 260 };
    readonly CheckBox keepHistory = new() { Text = "Save history", AutoSize = true };
    readonly ListView list = new() { View = View.Details, FullRowSelect = true, Dock = DockStyle.Fill, HideSelection = false };
    readonly TextBox detail = new() { Multiline = true, ReadOnly = true, ScrollBars = ScrollBars.Vertical, Dock = DockStyle.Fill };

    // Settings tab
    readonly ComboBox cleanup = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300 };
    readonly ComboBox polish = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 300 };
    readonly TextBox words = new() { Multiline = true, ScrollBars = ScrollBars.Vertical, Width = 520, Height = 80 };
    readonly CheckBox sounds = new() { Text = "Play start and stop sounds", AutoSize = true };
    readonly CheckBox atLogin = new() { Text = "Open at login", AutoSize = true };
    readonly Label status = new() { AutoSize = true, MaximumSize = new Size(560, 0) };
    readonly Label testResult = new() { AutoSize = true, MaximumSize = new Size(560, 0), ForeColor = Color.DimGray };

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public MainForm(HistoryStore history, Controller controller)
    {
        this.history = history;
        this.controller = controller;
        Text = "Prosperity Voice";
        Size = new Size(720, 640);
        MinimumSize = new Size(600, 480);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Segoe UI", 9.5f);
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); } catch { }

        tabs.TabPages.Add(BuildHistoryTab());
        tabs.TabPages.Add(BuildSettingsTab());
        Controls.Add(tabs);

        history.Changed += () => { if (IsHandleCreated) BeginInvoke(RefreshList); };
        RefreshList();
    }

    public void ShowTab(int index)
    {
        tabs.SelectedIndex = index;
        if (index == 1) RefreshStatus();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Show();
        Activate();
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // Closing the window just hides it; the app keeps running in the tray.
        if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
        base.OnFormClosing(e);
    }

    // MARK: History

    TabPage BuildHistoryTab()
    {
        var page = new TabPage("History");
        var top = new FlowLayoutPanel { Dock = DockStyle.Top, Height = 40, Padding = new Padding(6) };
        var copy = new Button { Text = "Copy", AutoSize = true };
        var delete = new Button { Text = "Delete", AutoSize = true };
        var clear = new Button { Text = "Clear all", AutoSize = true };
        top.Controls.AddRange([search, keepHistory, copy, delete, clear]);

        list.Columns.Add("When", 130);
        list.Columns.Add("App", 90);
        list.Columns.Add("AI", 70);
        list.Columns.Add("Text", 400);

        var split = new SplitContainer { Dock = DockStyle.Fill, Orientation = Orientation.Horizontal, SplitterDistance = 300 };
        split.Panel1.Controls.Add(list);
        split.Panel2.Controls.Add(detail);
        page.Controls.Add(split);
        page.Controls.Add(top);

        keepHistory.Checked = Settings.Current.KeepHistory;
        keepHistory.CheckedChanged += (_, _) => { Settings.Current.KeepHistory = keepHistory.Checked; Settings.Current.Save(); };
        search.TextChanged += (_, _) => RefreshList();
        list.SelectedIndexChanged += (_, _) => ShowDetail();
        copy.Click += (_, _) => { if (Selected() is { } e) Inserter.SetClipboard(e.Text); };
        delete.Click += (_, _) => { if (Selected() is { } e) history.Delete(e.Id); };
        clear.Click += (_, _) =>
        {
            if (MessageBox.Show(this, "This deletes every saved dictation and polish. It can't be undone.",
                    "Clear all history?", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) == DialogResult.OK)
                history.Clear();
        };
        return page;
    }

    HistoryEntry? Selected() => list.SelectedItems.Count > 0 ? list.SelectedItems[0].Tag as HistoryEntry : null;

    void RefreshList()
    {
        var q = search.Text.Trim();
        list.BeginUpdate();
        list.Items.Clear();
        foreach (var e in history.Entries)
        {
            if (q.Length > 0 && !e.Text.Contains(q, StringComparison.OrdinalIgnoreCase)
                && !e.Original.Contains(q, StringComparison.OrdinalIgnoreCase)) continue;
            var ai = e.Engine == "raw" ? "Raw" : char.ToUpperInvariant(e.Engine[0]) + e.Engine[1..];
            if (e.Kind == "polish") ai = "Polish · " + ai;
            var item = new ListViewItem([e.Date.ToLocalTime().ToString("MMM d, h:mm tt"), e.App ?? "", ai, e.Text.Replace("\n", " ")]) { Tag = e };
            list.Items.Add(item);
        }
        list.EndUpdate();
        detail.Text = history.Entries.Count == 0 ? "Nothing yet. Hold Right Ctrl and start talking." : "";
    }

    void ShowDetail()
    {
        if (Selected() is not { } e) return;
        var label = e.Kind == "polish" ? "Original text" : "What you actually said";
        detail.Text = e.Original == e.Text ? e.Text : $"{e.Text}\r\n\r\n— {label} —\r\n{e.Original}";
    }

    // MARK: Settings

    TabPage BuildSettingsTab()
    {
        var page = new TabPage("Settings") { AutoScroll = true };
        var col = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(14) };

        Label Header(string t) => new() { Text = t, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Margin = new Padding(0, 12, 0, 4) };
        Label Note(string t) => new() { Text = t, AutoSize = true, MaximumSize = new Size(560, 0), ForeColor = Color.DimGray };

        col.Controls.Add(Header("How to use"));
        col.Controls.Add(Note("Hold Right Ctrl and talk. Let go to paste.\r\nHands-free: hold Right Ctrl, tap Space, let go of both. Tap Right Ctrl to finish.\r\nEsc cancels. Nothing selected? The text goes to your clipboard.\r\nPolish: select text anywhere and press Ctrl+Alt+P."));

        col.Controls.Add(Header("Cleanup"));
        col.Controls.Add(new Label { Text = "Clean up dictation with", AutoSize = true });
        foreach (var e in Enum.GetValues<CleanupEngine>()) cleanup.Items.Add(EngineInfo.Label(e));
        col.Controls.Add(cleanup);
        col.Controls.Add(new Label { Text = "Polish selected text with", AutoSize = true, Margin = new Padding(0, 8, 0, 0) });
        foreach (var p in Enum.GetValues<Provider>()) polish.Items.Add(EngineInfo.Label(p));
        col.Controls.Add(polish);
        col.Controls.Add(Note("Claude, ChatGPT, and Grok run on your own subscriptions through their command-line tools, in a locked-down empty folder."));
        var test = new Button { Text = "Test cleanup AI", AutoSize = true };
        col.Controls.Add(test);
        col.Controls.Add(testResult);

        col.Controls.Add(Header("Words to spell right"));
        col.Controls.Add(words);
        col.Controls.Add(Note("Names, brands, and jargon, one per line or separated by commas. To always fix something it mishears, add a line like: Clawed => Claude"));

        col.Controls.Add(Header("General"));
        col.Controls.Add(sounds);
        col.Controls.Add(atLogin);
        var retry = new Button { Text = "Retry last recording", AutoSize = true };
        col.Controls.Add(retry);

        col.Controls.Add(Header("Status"));
        col.Controls.Add(status);
        var refresh = new Button { Text = "Refresh", AutoSize = true };
        col.Controls.Add(refresh);
        page.Controls.Add(col);

        var s = Settings.Current;
        cleanup.SelectedIndex = (int)s.CleanupEngine;
        polish.SelectedIndex = (int)s.PolishEngine;
        words.Text = s.CustomWords.Replace("\n", "\r\n");
        sounds.Checked = s.PlaySounds;
        atLogin.Checked = StartsAtLogin;

        cleanup.SelectedIndexChanged += (_, _) => { Settings.Current.CleanupEngine = (CleanupEngine)cleanup.SelectedIndex; Settings.Current.Save(); };
        polish.SelectedIndexChanged += (_, _) => { Settings.Current.PolishEngine = (Provider)polish.SelectedIndex; Settings.Current.Save(); };
        words.Leave += (_, _) => { Settings.Current.CustomWords = words.Text.Replace("\r\n", "\n"); Settings.Current.Save(); };
        sounds.CheckedChanged += (_, _) => { Settings.Current.PlaySounds = sounds.Checked; Settings.Current.Save(); };
        atLogin.CheckedChanged += (_, _) => { StartsAtLogin = atLogin.Checked; atLogin.Checked = StartsAtLogin; };
        retry.Click += (_, _) => controller.RetryLast();
        refresh.Click += (_, _) => RefreshStatus();
        test.Click += async (_, _) =>
        {
            var provider = EngineInfo.ProviderOf(Settings.Current.CleanupEngine) ?? Provider.Claude;
            testResult.Text = $"Testing {ProviderInfo.Name(provider)}…";
            var start = DateTime.Now;
            try
            {
                var output = await Cleaner.Run("so um this is uh a test of the the cleanup", Mode.Dictation, provider, []);
                testResult.Text = $"{ProviderInfo.Name(provider)} works ({(DateTime.Now - start).TotalSeconds:0.0}s): {output}";
            }
            catch (Exception ex) { testResult.Text = ex.Message; }
        };
        return page;
    }

    void RefreshStatus()
    {
        string Found(Provider p) => Cleaner.IsAvailable(p) ? "found" : "not found";
        status.Text =
            $"Microphone: {(Recorder.HasMicrophone ? "found" : "not found")}\r\n" +
            $"Speech model: {(Whisperer.ModelReady ? "ready" : "downloading or missing")}\r\n" +
            $"Talk key (keyboard hook): {(controller.Hotkey.IsRunning ? "running" : "not running")}\r\n" +
            $"Claude tool (claude): {Found(Provider.Claude)}\r\n" +
            $"ChatGPT tool (codex): {Found(Provider.ChatGPT)}\r\n" +
            $"Grok tool (grok): {Found(Provider.Grok)}";
    }

    public static bool StartsAtLogin
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey);
            return key?.GetValue("Prosperity Voice") is string;
        }
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue("Prosperity Voice", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("Prosperity Voice", throwOnMissingValue: false);
        }
    }
}
