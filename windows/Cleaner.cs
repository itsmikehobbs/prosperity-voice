using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace ProsperityVoice;

public sealed class CleanException(string message) : Exception(message)
{
    public static CleanException Rejected() => new("The AI changed the text too much, so it was skipped.");
    public bool IsRejected => Message.StartsWith("The AI changed the text too much");
}

/// <summary>Result of a cleanup or polish run.</summary>
public sealed record CleanResult(string Text, string Engine, string? Note = null);

public enum Mode { Dictation, Polish }

/// <summary>
/// Port of the Mac Cleaner. The base instructions come from shared/*.txt, exported from the Mac app
/// (ProsperityVoice --export-shared shared), so both apps follow the same rules.
/// </summary>
public static class Cleaner
{
    public const int ChunkWords = 2500;

    static string Resource(string name)
    {
        using var s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
            ?? throw new InvalidOperationException($"missing resource {name}");
        using var r = new StreamReader(s);
        return r.ReadToEnd().Trim();
    }

    static readonly Lazy<string> DictationBase = new(() => Resource("dictation-instructions.txt"));
    static readonly Lazy<string> PolishBase = new(() => Resource("polish-instructions.txt"));

    public static string Tag(Mode m) => m == Mode.Dictation ? "transcript" : "text";

    /// <summary>Same text the Mac app builds for its cloud AIs (fixNames: true).</summary>
    public static string Instructions(Mode mode, List<string> words)
    {
        var s = mode == Mode.Dictation ? DictationBase.Value : PolishBase.Value;
        if (words.Count > 0)
        {
            s += "\n\nThe speaker often says these names and terms: " + string.Join(", ", words)
               + ".\nSpeech recognition often mishears them. When a word or phrase clearly sounds like one of them (for example \"My Cobbs\" for \"Mike Hobbs\", \"Cloudflirt\" for \"Cloudflare\"), write that name. Never swap in a name that sounds different, and leave ordinary words alone when they make sense as they are.";
        }
        return s;
    }

    /// <summary>Acceptable output word count range relative to the input, to catch answers/truncation.</summary>
    public static bool Accepts(Mode mode, string input, string output)
    {
        double n = WordCount(input), m = WordCount(output);
        if (m == 0) return false;
        if (n < 6) return m <= n + 8;
        return mode == Mode.Dictation
            ? m >= n * 0.3 && m <= n * 1.35 + 4
            : m >= n * 0.5 && m <= n * 1.6 + 6;
    }

    // MARK: Entry points

    /// <summary>Clean a dictation with the chosen engine. Never throws; falls back to the raw text.</summary>
    public static async Task<CleanResult> CleanDictation(string raw, CleanupEngine engine, List<string> words)
    {
        var provider = EngineInfo.ProviderOf(engine);
        if (provider == null) return new CleanResult(raw, "raw");
        try
        {
            var text = await Run(raw, Mode.Dictation, provider.Value, words);
            return new CleanResult(text, provider.Value.ToString().ToLowerInvariant());
        }
        catch (Exception e)
        {
            Log.Write($"cleanup failed ({provider}): {e.Message}");
            return new CleanResult(raw, "raw", "Cleanup skipped");
        }
    }

    /// <summary>Polish selected text. Throws so the caller can leave the selection untouched.</summary>
    public static async Task<CleanResult> Polish(string text, Provider provider, List<string> words)
    {
        var output = await Run(text, Mode.Polish, provider, words);
        return new CleanResult(output, provider.ToString().ToLowerInvariant());
    }

    /// <summary>Chunk, clean each piece, and guard each result. A rejected piece keeps its original
    /// text (dictation) or fails the whole run (polish).</summary>
    public static async Task<string> Run(string text, Mode mode, Provider provider, List<string> words)
    {
        var pieces = Chunks(text, ChunkWords);
        var instructions = Instructions(mode, words);

        async Task<string> CleanPiece(string piece)
        {
            var wrapped = $"<{Tag(mode)}>{piece}</{Tag(mode)}>";
            var raw = await AskHedged(provider, wrapped, instructions);
            var output = CapitalizeFirst(Tidy(raw, Tag(mode)));
            if (!Accepts(mode, piece, output) || AddedNames(piece, output, words).Count > 0)
                throw CleanException.Rejected();
            return output;
        }

        if (pieces.Count == 1) return await CleanPiece(pieces[0]);

        var outputs = new string?[pieces.Count];
        Exception? last = null;
        using var gate = new SemaphoreSlim(3);
        await Task.WhenAll(pieces.Select(async (piece, i) =>
        {
            await gate.WaitAsync();
            try { outputs[i] = await CleanPiece(piece); }
            catch (Exception e)
            {
                if (mode == Mode.Polish) throw;
                last = e;
            }
            finally { gate.Release(); }
        }));
        if (outputs.All(o => o == null)) throw last ?? CleanException.Rejected();
        // Pieces split at sentence ends; the model adds its own paragraph breaks inside each piece.
        return string.Join(" ", outputs.Select((o, i) => o ?? pieces[i]));
    }

    // MARK: Engines

    public static Task<string> Ask(Provider provider, string prompt, string instructions, CancellationToken ct = default) => provider switch
    {
        Provider.Claude => Claude(prompt, instructions, ct),
        Provider.ChatGPT => ChatGPT(prompt, instructions, ct),
        _ => Grok(prompt, instructions, ct),
    };

    /// <summary>The AI tools usually answer in 2 to 6 seconds, but a call sometimes stalls for 20 to
    /// 30 (a busy server, or the tool retrying). If the first call is slow, start a second one and use
    /// whichever answers first; the other is stopped. Give up at the hard limit.
    /// Seen 2026-11-04: Claude took 21 and 33 seconds for 70 to 80 words.</summary>
    public static Task<string> AskHedged(Provider provider, string prompt, string instructions)
    {
        double words = WordCount(prompt);
        return Hedged(provider, 7.0 + words / 40, 25.0 + words / 15,
            ct => Ask(provider, prompt, instructions, ct));
    }

    /// <summary>The racing behind AskHedged, separate so the self-test can drive it with fake calls.</summary>
    public static async Task<string> Hedged(Provider provider, double hedgeAfter, double giveUpAfter,
                                            Func<CancellationToken, Task<string>> attempt)
    {
        using var cts = new CancellationTokenSource();
        var started = Stopwatch.StartNew();
        var first = Task.Run(() => attempt(cts.Token));
        var second = Task.Run(async () =>
        {
            await Task.Delay(TimeSpan.FromSeconds(hedgeAfter), cts.Token);
            Log.Write($"cleanup slow: {ProviderInfo.Name(provider)} asked again after {(int)hedgeAfter}s");
            return await attempt(cts.Token);
        });
        var deadline = Task.Delay(TimeSpan.FromSeconds(giveUpAfter), cts.Token);
        var pending = new List<Task> { first, second, deadline };
        try
        {
            var failures = 0;
            while (true)
            {
                var done = await Task.WhenAny(pending);
                pending.Remove(done);
                if (done == deadline)
                    throw new CleanException($"{ProviderInfo.Name(provider)} cleanup failed: timed out after {(int)giveUpAfter}s");
                var call = (Task<string>)done;
                if (call.IsCompletedSuccessfully) return call.Result;
                failures++;
                // A quick failure (not logged in, missing tool) won't fix itself: stop now.
                // After the second call has started, wait for it.
                var secondRunning = started.Elapsed.TotalSeconds >= hedgeAfter && failures < 2;
                if (!secondRunning) await call;   // rethrows its error
            }
        }
        finally
        {
            cts.Cancel();   // stops the slower call's tool and the timers
            foreach (var t in new Task[] { first, second, deadline })
                _ = t.ContinueWith(x => _ = x.Exception, TaskScheduler.Default);   // observe leftover errors
        }
    }

    /// <summary>Claude Code (`claude -p`) with every extra turned off: no tools, MCP, settings, or
    /// memory. Instructions go in a file and the text through standard input, because Windows
    /// mangles long multi-line command arguments.</summary>
    static async Task<string> Claude(string prompt, string instructions, CancellationToken ct)
    {
        var sp = TempFile("system", instructions);
        try
        {
            return await RunTool(Provider.Claude,
            [
                "-p", "--model", ProviderInfo.ClaudeModel, "--effort", "low",
                "--system-prompt-file", sp,
                "--tools", "",
                "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}",
                "--setting-sources", "",
                "--no-session-persistence",
            ], stdin: prompt, timeoutWords: WordCount(prompt), ct: ct);
        }
        finally { TryDelete(sp); }
    }

    /// <summary>Codex (`codex exec`): read-only sandbox, empty folder, no saved session, user config
    /// and rules skipped. The whole prompt goes through standard input ("-").</summary>
    static async Task<string> ChatGPT(string prompt, string instructions, CancellationToken ct)
    {
        var outFile = Path.Combine(Paths.AiOutput, $"{Guid.NewGuid()}.txt");
        try
        {
            var full = instructions + "\n- Never run commands, use tools, or read files.\n\n" + prompt;
            return await RunTool(Provider.ChatGPT,
            [
                "exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                "--sandbox", "read-only", "-C", Paths.AiWorkdir,
                "-m", ProviderInfo.ChatGPTModel, "-c", "model_reasoning_effort=low", "-c", "service_tier=fast",
                "-o", outFile, "-",
            ], stdin: full, outputFile: outFile, timeoutWords: WordCount(prompt), ct: ct);
        }
        finally { TryDelete(outFile); }
    }

    /// <summary>xAI's own Grok tool, single turn, with tools, web search, subagents, and planning
    /// off. It ignores --system-prompt-override on a grok.com login, so the instructions go first in
    /// the prompt, from a file, sent verbatim.</summary>
    static async Task<string> Grok(string prompt, string instructions, CancellationToken ct)
    {
        var full = instructions + "\n- Never run commands, use tools, or read files.\n\n" + prompt;
        var promptFile = TempFile("grok", full);
        try
        {
            return await RunTool(Provider.Grok,
            [
                "--prompt-file", promptFile, "--verbatim",
                "--model", ProviderInfo.GrokModel, "--reasoning-effort", "low",
                "--tools", "", "--disable-web-search", "--no-subagents", "--no-plan", "--max-turns", "1",
                "--cwd", Paths.AiWorkdir,
            ], stdin: null, timeoutWords: WordCount(prompt), ct: ct);
        }
        finally { TryDelete(promptFile); }
    }

    // MARK: Finding and running the command-line tools

    /// <summary>How to start a tool: the program plus any arguments that go before ours.</summary>
    public sealed record ToolCommand(string FileName, string[] Prefix, bool ViaCmd);

    static readonly Dictionary<Provider, ToolCommand?> ToolCache = [];

    public static bool IsAvailable(Provider p) => FindTool(p) != null;

    public static ToolCommand? FindTool(Provider provider)
    {
        lock (ToolCache)
        {
            if (ToolCache.TryGetValue(provider, out var cached) && cached != null) return cached;
            var found = Locate(ProviderInfo.Tool(provider));
            ToolCache[provider] = found;
            return found;
        }
    }

    static IEnumerable<string> SearchDirs()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        string[] known =
        [
            Path.Combine(home, ".local", "bin"),
            Path.Combine(home, ".grok", "bin"),
            Path.Combine(appData, "npm"),
            Path.Combine(local, "Microsoft", "WinGet", "Links"),
        ];
        var path = (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries);
        return known.Concat(path).Distinct(StringComparer.OrdinalIgnoreCase);
    }

    static ToolCommand? Locate(string name)
    {
        foreach (var dir in SearchDirs())
        {
            var exe = Path.Combine(dir, name + ".exe");
            if (File.Exists(exe)) return new ToolCommand(exe, [], false);
        }
        foreach (var dir in SearchDirs())
        {
            var cmd = Path.Combine(dir, name + ".cmd");
            if (!File.Exists(cmd)) continue;
            // npm-style shims call "node <script>": run that directly so arguments keep their
            // newlines and quotes (cmd.exe would mangle them).
            var body = File.ReadAllText(cmd);
            var script = Regex.Match(body, @"%~?dp0%?\\([^""%]+\.(?:js|mjs|cjs))", RegexOptions.IgnoreCase);
            if (script.Success)
            {
                var scriptPath = Path.Combine(dir, script.Groups[1].Value);
                var node = File.Exists(Path.Combine(dir, "node.exe")) ? Path.Combine(dir, "node.exe") : FindOnPath("node.exe");
                if (node != null && File.Exists(scriptPath)) return new ToolCommand(node, [scriptPath], false);
            }
            var innerExe = Regex.Match(body, @"%~?dp0%?\\([^""%]+\.exe)", RegexOptions.IgnoreCase);
            if (innerExe.Success)
            {
                var exePath = Path.Combine(dir, innerExe.Groups[1].Value);
                if (File.Exists(exePath)) return new ToolCommand(exePath, [], false);
            }
            return new ToolCommand(cmd, [], true);   // last resort: through cmd.exe
        }
        return null;
    }

    static string? FindOnPath(string file) =>
        (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries)
            .Select(d => Path.Combine(d, file)).FirstOrDefault(File.Exists);

    /// <summary>Run one of the AI command-line tools and return its answer (stdout, or outputFile).</summary>
    /// <summary>Number of AI tools running right now (the self-test checks a stopped call ends).</summary>
    public static int RunningTools => runningTools;
    static int runningTools;

    static async Task<string> RunTool(Provider provider, string[] args, string? stdin, int timeoutWords,
                                      string? outputFile = null, CancellationToken ct = default)
    {
        var tool = FindTool(provider) ?? throw new CleanException(
            $"Couldn't find the {ProviderInfo.Tool(provider)} command-line tool for {ProviderInfo.Name(provider)}.");
        var timeout = TimeSpan.FromSeconds(45 + timeoutWords / 20.0);

        var psi = new ProcessStartInfo
        {
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = Paths.AiWorkdir,
            StandardInputEncoding = new UTF8Encoding(false),
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        if (tool.ViaCmd)
        {
            // cmd.exe can't carry newlines in arguments: flatten them (only used when no direct
            // program could be found).
            psi.FileName = Environment.GetEnvironmentVariable("ComSpec") ?? "cmd.exe";
            var line = string.Join(" ", new[] { tool.FileName }.Concat(args).Select(a => QuoteForCmd(a.Replace("\r", " ").Replace("\n", " "))));
            psi.Arguments = $"/d /s /c \"{line}\"";
        }
        else
        {
            psi.FileName = tool.FileName;
            foreach (var a in tool.Prefix.Concat(args)) psi.ArgumentList.Add(a);
        }

        ct.ThrowIfCancellationRequested();
        using var p = new Process { StartInfo = psi };
        try { p.Start(); }
        catch (Exception e) { throw new CleanException($"{ProviderInfo.Name(provider)} cleanup failed: {e.Message}"); }
        Interlocked.Increment(ref runningTools);
        try
        {
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            if (stdin != null) await p.StandardInput.WriteAsync(stdin);
            p.StandardInput.Close();

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException)
            {
                try { p.Kill(entireProcessTree: true); } catch { }
                ct.ThrowIfCancellationRequested();   // stopped on purpose (a faster call won)
                throw new CleanException($"{ProviderInfo.Name(provider)} cleanup failed: timed out");
            }
            var stdout = await outTask;
            var stderr = await errTask;
            var answer = outputFile != null && File.Exists(outputFile) ? File.ReadAllText(outputFile) : stdout;
            answer = answer.Trim();
            if (p.ExitCode == 0 && answer.Length > 0) return answer;
            var why = stderr.Trim().Length > 0 ? stderr.Trim() : answer;
            throw new CleanException($"{ProviderInfo.Name(provider)} cleanup failed: {Tail(why, 200)}");
        }
        finally { Interlocked.Decrement(ref runningTools); }
    }

    static string QuoteForCmd(string a) =>
        a.Length > 0 && !a.Any(c => c is ' ' or '"' or '&' or '|' or '<' or '>' or '^' or '%') ? a : "\"" + a.Replace("\"", "\\\"") + "\"";

    static string TempFile(string kind, string content)
    {
        var path = Path.Combine(Paths.AiOutput, $"{kind}-{Guid.NewGuid()}.txt");
        File.WriteAllText(path, content, new UTF8Encoding(false));
        return path;
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    static string Tail(string s, int n) => s.Length <= n ? s : s[^n..];

    // MARK: Helpers (same behavior as the Mac app)

    public static int WordCount(string s) => s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;

    public static string CapitalizeFirst(string s)
    {
        for (var i = 0; i < s.Length; i++)
        {
            if (!char.IsLetter(s[i])) continue;
            return char.IsLower(s[i]) ? s[..i] + char.ToUpperInvariant(s[i]) + s[(i + 1)..] : s;
        }
        return s;
    }

    /// <summary>Strip echoed tags, curly quotes, wrapping quotes, and "Here is the cleaned text:" preambles.</summary>
    public static string Tidy(string s, string tag)
    {
        var t = Regex.Replace(s, $"</?{tag}>", "").Trim();
        // Plain quotes, so every AI matches what you type yourself.
        t = t.Replace('’', '\'').Replace('‘', '\'').Replace('“', '"').Replace('”', '"');
        var nl = t.IndexOf('\n');
        var firstLine = nl >= 0 ? t[..nl] : t;
        var lower = firstLine.ToLowerInvariant();
        if (firstLine.EndsWith(':') && (lower.StartsWith("here") || lower.StartsWith("sure")))
            t = t[firstLine.Length..].Trim();
        if (t.Length > 1 && t.StartsWith('"') && t.EndsWith('"') && !t[1..^1].Contains('"'))
            t = t[1..^1];
        return t;
    }

    static readonly HashSet<string> CommonCapitalized = ["I", "OK", "Okay", "Mr", "Mrs", "Ms", "Dr", "AM", "PM"];

    /// <summary>Capitalized words in the output that were never said (like "Paris" when the speaker
    /// asked about France). A sign the model answered instead of cleaning up.</summary>
    public static List<string> AddedNames(string input, string output, List<string> allowed)
    {
        static IEnumerable<string> Words(string s) => Regex.Split(s, @"[^\p{L}]+").Where(w => w.Length > 0);
        var known = new HashSet<string>(Words(input).Concat(allowed.SelectMany(Words)).Select(w => w.ToLowerInvariant()));
        var added = new List<string>();
        var sentenceStart = true;
        foreach (var token in output.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries))
        {
            var word = token.Trim().Trim(token.Where(c => !char.IsLetter(c)).Distinct().ToArray());
            var startsSentence = sentenceStart;
            sentenceStart = ".!?:".Contains(token[^1]);
            if (word.Length <= 1 || !char.IsUpper(word[0]) || startsSentence) continue;
            foreach (var part in Words(word))
                if (!known.Contains(part.ToLowerInvariant()) && !CommonCapitalized.Contains(part)) added.Add(part);
        }
        return added;
    }

    /// <summary>Split at sentence ends into pieces of at most maxWords (a longer sentence is cut by words).</summary>
    public static List<string> Chunks(string text, int maxWords)
    {
        var trimmed = text.Trim();
        if (WordCount(trimmed) <= maxWords) return [trimmed];

        var sentences = new List<string>();
        var current = new StringBuilder();
        foreach (var ch in trimmed)
        {
            current.Append(ch);
            if (".!?\n".Contains(ch)) { sentences.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) sentences.Add(current.ToString());

        var pieces = new List<string>();
        var piece = new StringBuilder();
        var count = 0;
        void Flush()
        {
            var joined = piece.ToString().Trim();
            if (joined.Length > 0) pieces.Add(joined);
            piece.Clear();
            count = 0;
        }
        foreach (var sentence in sentences)
        {
            var n = WordCount(sentence);
            if (n > maxWords)
            {
                Flush();
                var ws = sentence.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
                for (var i = 0; i < ws.Length; i += maxWords)
                    pieces.Add(string.Join(" ", ws.Skip(i).Take(maxWords)));
                continue;
            }
            if (count + n > maxWords) Flush();
            piece.Append(sentence);
            count += n;
        }
        Flush();
        return pieces;
    }
}
