namespace ProsperityVoice;

static class Program
{
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);

    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();

        if (args.Contains("--selftest"))
        {
            AttachConsole(-1);   // print to the console that started us (it's a windowed app)
            var cloud = Enum.GetValues<Provider>().Where(p => args.Contains("--" + p.ToString().ToLowerInvariant())).ToList();
            return SelfTest.Run(cloud, includeSpeech: !args.Contains("--fast")).GetAwaiter().GetResult();
        }

        var set = Array.IndexOf(args, "--set-cleanup");
        if (set >= 0)
        {
            // Used by the installer after asking the user: --set-cleanup claude|chatgpt|grok|off
            AttachConsole(-1);
            if (set + 1 >= args.Length || !Enum.TryParse<CleanupEngine>(args[set + 1], true, out var engine))
            {
                Console.WriteLine("Usage: --set-cleanup claude|chatgpt|grok|off");
                return 2;
            }
            Settings.Current.CleanupEngine = engine;
            if (EngineInfo.ProviderOf(engine) is Provider p) Settings.Current.PolishEngine = p;
            Settings.Current.CleanupChosen = true;
            Settings.Current.Save();
            Console.WriteLine($"Cleanup set to {EngineInfo.Label(engine)}");
            return 0;
        }

        // One copy at a time: a second launch just quits.
        using var single = new Mutex(true, @"Local\ProsperityVoice.SingleInstance", out var first);
        if (!first) return 0;

        Application.Run(new TrayApp());
        return 0;
    }
}

/// <summary>Tray icon, menu, and wiring. No main window until you open History or Settings.</summary>
sealed class TrayApp : ApplicationContext
{
    readonly NotifyIcon tray;
    readonly RecordingPanel panel = new();
    readonly HistoryStore history = new();
    readonly Controller controller;
    readonly Hotkey hotkey;
    readonly MainForm window;
    readonly ToolStripMenuItem toggleItem = new("Start recording");

    public TrayApp()
    {
        panel.CreateControl();
        _ = panel.Handle;   // the hook posts actions through this control
        hotkey = new Hotkey(panel);
        controller = new Controller(history, panel, hotkey);
        window = new MainForm(history, controller);

        var menu = new ContextMenuStrip();
        menu.Items.Add(new ToolStripMenuItem("Hold Right Ctrl to talk · Right Ctrl+Space for hands-free") { Enabled = false });
        menu.Items.Add(toggleItem);
        menu.Items.Add("Retry last recording", null, (_, _) => controller.RetryLast());
        menu.Items.Add(new ToolStripSeparator());
        var cleanupMenu = new ToolStripMenuItem("Cleanup");
        foreach (var engine in Enum.GetValues<CleanupEngine>())
        {
            var item = new ToolStripMenuItem(EngineInfo.Label(engine)) { Tag = engine };
            item.Click += (_, _) => { Settings.Current.CleanupEngine = engine; Settings.Current.Save(); };
            cleanupMenu.DropDownItems.Add(item);
        }
        cleanupMenu.DropDownOpening += (_, _) =>
        {
            foreach (ToolStripMenuItem i in cleanupMenu.DropDownItems) i.Checked = (CleanupEngine)i.Tag! == Settings.Current.CleanupEngine;
        };
        menu.Items.Add(cleanupMenu);
        menu.Items.Add("History…", null, (_, _) => window.ShowTab(0));
        menu.Items.Add("Settings…", null, (_, _) => window.ShowTab(1));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Quit Prosperity Voice", null, (_, _) => Quit());
        toggleItem.Click += (_, _) => controller.Toggle();
        menu.Opening += (_, _) => toggleItem.Text = controller.Current == Controller.Phase.Recording ? "Stop and paste" : "Start recording";

        tray = new NotifyIcon
        {
            Icon = AppIcon.Create(),
            Text = "Prosperity Voice",
            ContextMenuStrip = menu,
            Visible = true,
        };
        tray.DoubleClick += (_, _) => window.ShowTab(0);

        hotkey.Start();
        Log.Write($"launch v{Application.ProductVersion} hotkey={hotkey.IsRunning} mic={Recorder.HasMicrophone}");

        // First launch: open at login and show Settings.
        if (!Settings.Current.DidFirstLaunch)
        {
            Settings.Current.DidFirstLaunch = true;
            // Unless the user already chose (installer): clean up with an AI they already have,
            // Claude, then ChatGPT (Codex), then Grok. With none, Claude stays selected and text is
            // pasted uncleaned until one is installed.
            if (!Settings.Current.CleanupChosen)
            {
                var found = new[] { Provider.Claude, Provider.ChatGPT, Provider.Grok }.FirstOrDefault(Cleaner.IsAvailable, Provider.Claude);
                Settings.Current.CleanupEngine = found switch
                {
                    Provider.ChatGPT => CleanupEngine.ChatGPT,
                    Provider.Grok => CleanupEngine.Grok,
                    _ => CleanupEngine.Claude,
                };
                Settings.Current.PolishEngine = found;
                Log.Write($"first launch: cleanup set to {found}");
            }
            Settings.Current.Save();
            ProsperityVoice.MainForm.StartsAtLogin = true;
            window.ShowTab(1);
        }

        // Download the speech model in the background if it's missing.
        _ = Task.Run(async () =>
        {
            try { await Whisperer.EnsureModel(); }
            catch (Exception e) { Log.Write($"model download failed: {e.Message}"); }
        });
    }

    void Quit()
    {
        tray.Visible = false;
        hotkey.Dispose();
        ExitThread();
    }
}

/// <summary>The app icon, drawn in code: navy rounded square, yellow voice bars, red dot.</summary>
static class AppIcon
{
    public static Icon Create(int size = 64)
    {
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.Clear(Color.Transparent);
            using var bg = new SolidBrush(Brand.Navy);
            g.FillEllipse(bg, 1, 1, size - 2, size - 2);
            float[] heights = [0.25f, 0.5f, 0.75f, 0.55f, 0.85f, 0.6f, 0.4f, 0.22f];
            var barW = size / 16f;
            var gap = size / 30f;
            var total = heights.Length * barW + (heights.Length - 1) * gap;
            var x = (size - total) / 2;
            using var yellow = new SolidBrush(Brand.Yellow);
            foreach (var h in heights)
            {
                var bh = h * size * 0.55f;
                g.FillRectangle(yellow, x, (size - bh) / 2, barW, bh);
                x += barW + gap;
            }
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
