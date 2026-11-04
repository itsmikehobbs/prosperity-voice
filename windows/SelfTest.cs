using System.Diagnostics;

namespace ProsperityVoice;

/// <summary>Headless checks: ProsperityVoice.exe --selftest [--fast] [--claude] [--chatgpt] [--grok]
/// Results print to the console and to selftest.txt next to the log.</summary>
static class SelfTest
{
    static int failures;
    static readonly List<string> lines = [];

    static void Check(string name, bool ok, string detail = "")
    {
        var line = (ok ? "PASS " : "FAIL ") + name + (detail.Length > 0 ? " — " + detail : "");
        Console.WriteLine(line);
        lines.Add(line);
        if (!ok) failures++;
    }

    public static async Task<int> Run(List<Provider> cloud, bool includeSpeech)
    {
        GestureTests();
        TextTests();
        HistoryTests();
        await HedgeTests();
        if (includeSpeech) await SpeechTests();
        foreach (var p in cloud)
        {
            await CleanupTests(p);
            await HedgeLiveTest(p);
        }
        var summary = failures == 0 ? "ALL PASSED" : $"{failures} FAILED";
        Console.WriteLine("\n" + summary);
        lines.Add(summary);
        File.WriteAllLines(Path.Combine(Paths.Support, "selftest.txt"), lines);
        return failures == 0 ? 0 : 1;
    }

    // MARK: Gesture

    static void GestureTests()
    {
        var g = new Gesture();
        Check("hold: key down starts", g.Handle(new GestureEvent.KeyDown(0)) == (GestureAction.Start, false));
        Check("hold: key up finishes", g.Handle(new GestureEvent.KeyUp(2)) == (GestureAction.Finish, false));
        Check("hold: back to idle", g.Current == Gesture.State.Idle);

        g = new Gesture();
        g.Handle(new GestureEvent.KeyDown(0));
        Check("tap: short tap cancels", g.Handle(new GestureEvent.KeyUp(0.1)).Action == GestureAction.Cancel);

        g = new Gesture();
        g.Handle(new GestureEvent.KeyDown(0));
        Check("latch: Space latches and is swallowed", g.Handle(new GestureEvent.SpaceDown()) == (GestureAction.Latch, true));
        Check("latch: Space repeat swallowed", g.Handle(new GestureEvent.SpaceDown()) == (GestureAction.None, true));
        Check("latch: key release keeps recording", g.Handle(new GestureEvent.KeyUp(1)) == (GestureAction.None, false));
        Check("latch: Space release swallowed", g.Handle(new GestureEvent.SpaceUp()) == (GestureAction.None, true));
        Check("latch: typing Space later passes through", g.Handle(new GestureEvent.SpaceDown()) == (GestureAction.None, false));
        Check("latch: next press waits", g.Handle(new GestureEvent.KeyDown(5)).Action == GestureAction.None);
        Check("latch: its release finishes", g.Handle(new GestureEvent.KeyUp(5.1)).Action == GestureAction.Finish);
        Check("latch: idle again", g.Current == Gesture.State.Idle);

        g = new Gesture();
        g.Handle(new GestureEvent.KeyDown(0));
        g.Handle(new GestureEvent.SpaceDown());
        g.Handle(new GestureEvent.KeyUp(1));
        Check("latch: Esc cancels and is swallowed", g.Handle(new GestureEvent.Escape()) == (GestureAction.Cancel, true));

        g = new Gesture();
        g.Handle(new GestureEvent.KeyDown(0));
        Check("combo: Ctrl+key right away cancels, key passes", g.Handle(new GestureEvent.OtherKeyDown(0.3)) == (GestureAction.Cancel, false));
        Check("combo: release after combo does nothing", g.Handle(new GestureEvent.KeyUp(0.5)).Action == GestureAction.None);

        g = new Gesture();
        g.Handle(new GestureEvent.KeyDown(0));
        Check("combo: stray key late in a long hold is ignored", g.Handle(new GestureEvent.OtherKeyDown(5)).Action == GestureAction.None);
        Check("hold: Esc cancels", g.Handle(new GestureEvent.Escape()) == (GestureAction.Cancel, true));

        g = new Gesture();
        Check("idle: Esc passes through", g.Handle(new GestureEvent.Escape()) == (GestureAction.None, false));
        Check("idle: Space passes through", g.Handle(new GestureEvent.SpaceDown()) == (GestureAction.None, false));

        g = new Gesture();
        g.Handle(new GestureEvent.KeyDown(0));
        g.Reset();   // finished via the panel while the key is still held
        Check("reset while held: release is ignored", g.Handle(new GestureEvent.KeyUp(3)).Action == GestureAction.None && g.Current == Gesture.State.Idle);
    }

    // MARK: Text helpers (same cases as the Mac app)

    static void TextTests()
    {
        Check("chunk: short text is one piece", Cleaner.Chunks("one two three.", 10).SequenceEqual(["one two three."]));
        var sentences = string.Join(" ", Enumerable.Range(1, 40).Select(i => $"This is sentence number {i} of the test."));
        var pieces = Cleaner.Chunks(sentences, 50);
        Check("chunk: long text splits", pieces.Count > 1, $"{pieces.Count} pieces");
        Check("chunk: no piece over the limit", pieces.All(p => Cleaner.WordCount(p) <= 50));
        Check("chunk: pieces end at sentence ends", pieces.All(p => p.EndsWith('.')));
        Check("chunk: no words lost", pieces.Sum(Cleaner.WordCount) == Cleaner.WordCount(sentences));
        var cut = Cleaner.Chunks(string.Join(" ", Enumerable.Repeat("word", 130)), 50);
        Check("chunk: unpunctuated text cut by words", cut.Select(Cleaner.WordCount).SequenceEqual([50, 50, 30]));

        var input = string.Join(" ", Enumerable.Repeat("word", 40));
        Check("guard: similar length accepted", Cleaner.Accepts(Mode.Dictation, input, string.Join(" ", Enumerable.Repeat("word", 34))));
        Check("guard: answer-like short output rejected", !Cleaner.Accepts(Mode.Dictation, input, "Paris."));
        Check("guard: runaway output rejected", !Cleaner.Accepts(Mode.Dictation, input, string.Join(" ", Enumerable.Repeat("word", 120))));
        Check("guard: empty rejected", !Cleaner.Accepts(Mode.Dictation, input, ""));
        Check("tidy: strips tags", Cleaner.Tidy("<transcript>Hi there.</transcript>", "transcript") == "Hi there.");
        Check("tidy: strips preamble", Cleaner.Tidy("Here is the cleaned text:\nHi there.", "transcript") == "Hi there.");
        Check("tidy: strips wrapping quotes", Cleaner.Tidy("\"Hi there.\"", "transcript") == "Hi there.");
        Check("tidy: keeps inner quotes", Cleaner.Tidy("He said \"hi\" to me.", "text") == "He said \"hi\" to me.");
        Check("tidy: straightens curly quotes", Cleaner.Tidy("They’re “ready”.", "text") == "They're \"ready\".");
        Check("names: flags an invented name", Cleaner.AddedNames("what is the capital of france", "The capital of France is Paris.", []).SequenceEqual(["Paris"]));
        Check("names: allows names that were said", Cleaner.AddedNames("call jim about the cake", "Then call Jim about the cake.", []).Count == 0);
        Check("names: allows custom words", Cleaner.AddedNames("ask mike hobs", "Ask Mike Hobbs.", ["Mike Hobbs"]).Count == 0);
        Check("names: ignores sentence starts", Cleaner.AddedNames("ok so then we go", "Okay. Then we go.", []).Count == 0);
        Check("capitalize first letter", Cleaner.CapitalizeFirst("so then") == "So then" && Cleaner.CapitalizeFirst("\"hi\"") == "\"Hi\"");

        var rules = Settings.ParseReplacements("Mike Hobbs, My Cobbs => Mike Hobbs\ncloudflirt=>Cloudflare, red => blue, blue => green");
        Check("fixes: parsed", rules.Count == 4 && Settings.ParseWords("a, b => c").SequenceEqual(["a"]));
        Check("fixes: whole words, any case", Settings.ApplyReplacements("ask my cobbs about Cloudflirt today", rules) == "ask Mike Hobbs about Cloudflare today");
        Check("fixes: one pass, no chains", Settings.ApplyReplacements("red blue", rules) == "blue green");
        Check("fixes: not inside other words", Settings.ApplyReplacements("bluebird and redo", rules) == "bluebird and redo");
        Check("fixes: longest phrase wins", Settings.ApplyReplacements("my cobbs tv", [("my cobbs", "Mike Hobbs"), ("my cobbs tv", "Mike Hobbs TV")]) == "Mike Hobbs TV");
        Check("words: parse commas and lines", Settings.ParseWords("Mike Hobbs, HBA\nCloudflare,, ").SequenceEqual(["Mike Hobbs", "HBA", "Cloudflare"]));
        Check("instructions: shared dictation rules loaded", Cleaner.Instructions(Mode.Dictation, []).Contains("<transcript>"));
        Check("instructions: shared polish rules loaded", Cleaner.Instructions(Mode.Polish, []).Contains("<text>"));
        Check("instructions: word list added", Cleaner.Instructions(Mode.Dictation, ["Mike Hobbs"]).Contains("Mike Hobbs"));
    }

    // MARK: History

    static void HistoryTests()
    {
        var path = Path.Combine(Path.GetTempPath(), $"pv-history-{Guid.NewGuid()}.json");
        try
        {
            var store = new HistoryStore(path);
            var a = new HistoryEntry { Original = "um hello", Text = "um hello" };
            store.Add(a);
            store.Update(a.Id, e => { e.Text = "Hello."; e.Engine = "claude"; });
            store.Add(new HistoryEntry { Kind = "polish", Original = "x", Text = "X.", Engine = "claude" });
            var reloaded = new HistoryStore(path);
            Check("history: reload keeps entries newest first", reloaded.Entries.Count == 2 && reloaded.Entries[0].Kind == "polish");
            Check("history: update saved", reloaded.Entries[1].Text == "Hello." && reloaded.Entries[1].Original == "um hello");
            reloaded.Delete(a.Id);
            Check("history: delete", new HistoryStore(path).Entries.Count == 1);
            reloaded.Clear();
            Check("history: clear", new HistoryStore(path).Entries.Count == 0);
            File.WriteAllText(path, "not json");
            Check("history: damaged file doesn't crash", new HistoryStore(path).Entries.Count == 0);
        }
        finally
        {
            foreach (var f in Directory.GetFiles(Path.GetTempPath(), Path.GetFileNameWithoutExtension(path) + "*")) File.Delete(f);
        }
    }

    // MARK: Speech (Windows text-to-speech makes the audio)

    static async Task SpeechTests()
    {
        var sw = Stopwatch.StartNew();
        try { await Whisperer.EnsureModel(); }
        catch (Exception e) { Check("speech: model download", false, e.Message); return; }
        Check("speech: model ready", Whisperer.ModelReady, $"{sw.Elapsed.TotalSeconds:0}s");

        var clip = Path.Combine(Path.GetTempPath(), "pv-speech.wav");
        var sentence = "Please schedule the meeting with Sarah for next Tuesday at the downtown office.";
        if (!Speak(sentence, clip)) { Check("speech: generate audio", false, "Windows text-to-speech failed"); return; }
        sw.Restart();
        var samples = Whisperer.ReadWav(clip);
        string text;
        try { text = await Whisperer.Transcribe(samples, ["Sarah"]); }
        catch (Exception e)
        {
            Check("speech: speech engine loads", false, e.Message +
                  " (needs the Microsoft Visual C++ Redistributable: winget install --id Microsoft.VCRedist.2015+.x64 -e)");
            return;
        }
        var lower = text.ToLowerInvariant();
        var hits = new[] { "schedule", "meeting", "sarah", "tuesday", "downtown", "office" }.Count(lower.Contains);
        Check("speech: transcribes a spoken sentence", hits >= 5, $"\"{text}\" in {sw.Elapsed.TotalSeconds:0.0}s");

        var silence = new float[16000 * 2];
        Check("speech: silence counts as no speech", Whisperer.PeakDb(silence) < Whisperer.SpeechThresholdDb);
        File.Delete(clip);
    }

    /// <summary>Use Windows' built-in voice (System.Speech via PowerShell) to make a test WAV.</summary>
    static bool Speak(string text, string wav)
    {
        var script = "Add-Type -AssemblyName System.Speech; $s = New-Object System.Speech.Synthesis.SpeechSynthesizer; " +
                     $"$s.SetOutputToWaveFile('{wav}'); $s.Speak('{text.Replace("'", "''")}'); $s.Dispose()";
        var p = Process.Start(new ProcessStartInfo("powershell", ["-NoProfile", "-Command", script]) { CreateNoWindow = true, UseShellExecute = false });
        p?.WaitForExit(60000);
        return File.Exists(wav) && new FileInfo(wav).Length > 1000;
    }

    // MARK: Cleanup

    // MARK: Asking again when the AI is slow

    /// <summary>A slow AI call gets a second try; the first answer wins; quick failures and hangs end fast.</summary>
    static async Task HedgeTests()
    {
        async Task<(string? Out, double Secs, int Calls)> Timed(double hedge, double giveUp, Func<int, CancellationToken, Task<string>> attempt)
        {
            var calls = 0;
            var sw = Stopwatch.StartNew();
            string? output = null;
            try { output = await Cleaner.Hedged(Provider.Claude, hedge, giveUp, ct => attempt(Interlocked.Increment(ref calls), ct)); }
            catch { }
            return (output, sw.Elapsed.TotalSeconds, calls);
        }
        var r = await Timed(0.3, 2, (_, _) => Task.FromResult("fast"));
        Check("hedge: a quick answer is used, no second call", r.Out == "fast" && r.Calls == 1, r.ToString());
        r = await Timed(0.3, 2, async (n, ct) =>
        {
            if (n == 1) await Task.Delay(1500, ct);
            return $"call {n}";
        });
        Check("hedge: a slow call gets a second try that wins", r.Out == "call 2" && r.Secs < 0.9, r.ToString());
        r = await Timed(0.3, 2, (_, _) => throw new CleanException("Claude cleanup failed: Not logged in"));
        Check("hedge: a quick failure stops at once", r.Out == null && r.Secs < 0.2 && r.Calls == 1, r.ToString());
        r = await Timed(0.2, 0.6, async (_, ct) => { await Task.Delay(5000, ct); return "late"; });
        Check("hedge: gives up at the limit", r.Out == null && r.Secs < 1.0 && r.Calls == 2, r.ToString());
    }

    /// <summary>Two real calls at once: the first answer is used and the other tool is stopped.</summary>
    static async Task HedgeLiveTest(Provider provider)
    {
        if (!Cleaner.IsAvailable(provider)) return;
        var label = provider.ToString().ToLowerInvariant();
        string? output = null;
        try
        {
            var instructions = Cleaner.Instructions(Mode.Dictation, []);
            output = await Cleaner.Hedged(provider, 0, 60,
                ct => Cleaner.Ask(provider, "<transcript>um so this is a test</transcript>", instructions, ct));
        }
        catch (Exception e) { output = null; Check($"hedge {label}: call", false, e.Message); }
        await Task.Delay(1000);
        Check($"hedge {label}: two calls race, the slower one is stopped",
              !string.IsNullOrEmpty(output) && Cleaner.RunningTools == 0, $"out={output} running={Cleaner.RunningTools}");
    }

    static async Task CleanupTests(Provider provider)
    {
        var label = provider.ToString().ToLowerInvariant();
        if (!Cleaner.IsAvailable(provider)) { Check($"{label}: tool installed", false, "not found"); return; }

        async Task<string?> Clean(string s, List<string>? words = null)
        {
            try { return await Cleaner.Run(s, Mode.Dictation, provider, words ?? ["Jim"]); }
            catch (Exception e) { Check($"{label}: call", false, e.Message); return null; }
        }

        var sw = Stopwatch.StartNew();
        if (await Clean("so um i was thinking we should like go to the store tomorow and get some stuff for the party and uh then maybe we can you know call jim about the the cake") is { } o1)
        {
            var l = o1.ToLowerInvariant();
            Check($"{label}: removes fillers", !l.Contains(" um ") && !l.Contains(" uh ") && !l.Contains("you know"), $"{o1} ({sw.Elapsed.TotalSeconds:0.0}s)");
            Check($"{label}: keeps content", l.Contains("store") && l.Contains("party") && l.Contains("cake") && o1.Contains("Jim"));
        }
        if (await Clean("so um me and him was gonna head over to the warehouse thursday") is { } o2)
            Check($"{label}: fixes pronouns and verbs", o2.Contains("He and I were"), o2);
        if (await Clean("lets meet on saturday no wait sunday at the coffee shop on main street") is { } o3)
            Check($"{label}: self-correction keeps the final choice", o3.ToLowerInvariant().Contains("sunday") && !o3.ToLowerInvariant().Contains("saturday"), o3);
        if (await Clean("what is the capital of france and how many people live there") is { } o4)
            Check($"{label}: doesn't answer questions", !o4.ToLowerInvariant().Contains("paris"), o4);
        if (await Clean("We are going to post two videos a week. Tuesday video is going... You and the Friday video is going to be a tutorial.") is { } o5)
            Check($"{label}: doesn't guess at garbled words", o5.Split("tutorial").Length - 1 == 1, o5);
        if (await Clean("I might ask Cloud to update the My Cobbs TV site on Cloudflirt, and up host it in the HBA group.",
                ["Mike Hobbs", "Mike Hobbs TV", "HBA", "Claude", "Cloudflare"]) is { } o6)
            Check($"{label}: fixes misheard names from the word list", o6.Contains("Mike Hobbs TV") && o6.Contains("Cloudflare"), o6);
        try
        {
            var p = await Cleaner.Run("their going to announce the the new product next week, its really good and every body will like it", Mode.Polish, provider, []);
            Check($"{label}: polish fixes grammar", p.Contains("They're") || p.Contains("They are"), p);
        }
        catch (Exception e) { Check($"{label}: polish fixes grammar", false, e.Message); }
    }
}
