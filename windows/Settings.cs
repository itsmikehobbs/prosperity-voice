using System.Text.Json;
using System.Text.RegularExpressions;

namespace ProsperityVoice;

/// <summary>The AI services that can clean up text. Same picks as the Mac app (tested 2026-09-28
/// and 2026-10-09): one model per service. Apple isn't available on Windows.</summary>
public enum Provider { Claude, ChatGPT, Grok }

public static class ProviderInfo
{
    public const string ClaudeModel = "claude-sonnet-5-5";
    public const string ChatGPTModel = "gpt-6.1-sol";
    /// <summary>Grok 4.7 at low effort through xAI's own `grok` tool (grok.com login), not Cursor.</summary>
    public const string GrokModel = "grok-4.7";

    public static string Name(Provider p) => p switch
    {
        Provider.Claude => "Claude",
        Provider.ChatGPT => "ChatGPT",
        _ => "Grok",
    };

    /// <summary>Command-line tool that runs the model on the user's own subscription.</summary>
    public static string Tool(Provider p) => p switch
    {
        Provider.Claude => "claude",
        Provider.ChatGPT => "codex",
        _ => "grok",
    };
}

/// <summary>Which AI cleans up a dictation. "Off" pastes the raw transcript.</summary>
public enum CleanupEngine { Claude, ChatGPT, Grok, Off }

public static class EngineInfo
{
    public static Provider? ProviderOf(CleanupEngine e) => e switch
    {
        CleanupEngine.Claude => Provider.Claude,
        CleanupEngine.ChatGPT => Provider.ChatGPT,
        CleanupEngine.Grok => Provider.Grok,
        _ => null,
    };

    public static string Label(CleanupEngine e) => e switch
    {
        CleanupEngine.Claude => "Claude Sonnet 5.5 (~3 sec)",
        CleanupEngine.ChatGPT => "ChatGPT Sol 6.1 (~4 sec)",
        CleanupEngine.Grok => "Grok 4.7 (~7 sec)",
        _ => "Off (paste the raw transcript)",
    };

    public static string Label(Provider p) => p switch
    {
        Provider.Claude => "Claude Sonnet 5.5",
        Provider.ChatGPT => "ChatGPT Sol 6.1",
        _ => "Grok 4.7",
    };
}

/// <summary>Settings saved as JSON in %APPDATA%\Prosperity Voice\settings.json.</summary>
public sealed class Settings
{
    public const string DefaultWords = "";

    public CleanupEngine CleanupEngine { get; set; } = CleanupEngine.Claude;
    public Provider PolishEngine { get; set; } = Provider.Claude;
    public string CustomWords { get; set; } = DefaultWords;
    public bool PlaySounds { get; set; } = true;
    public bool KeepHistory { get; set; } = true;
    public bool DidFirstLaunch { get; set; }
    /// <summary>True once the user picked a cleanup AI (installer or Settings), so first launch keeps it.</summary>
    public bool CleanupChosen { get; set; }

    static readonly object Gate = new();
    /// <summary>Engines saved by name ("Claude"), readable by people and agents; old numeric files still load.</summary>
    static readonly JsonSerializerOptions Json = new() { WriteIndented = true, Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() } };
    static Settings? current;

    public static Settings Current
    {
        get
        {
            lock (Gate) { return current ??= Load(); }
        }
    }

    static Settings Load()
    {
        try
        {
            if (File.Exists(Paths.Settings))
                return JsonSerializer.Deserialize<Settings>(File.ReadAllText(Paths.Settings), Json) ?? new Settings();
        }
        catch { /* damaged file: start fresh */ }
        return new Settings();
    }

    public void Save()
    {
        lock (Gate)
        {
            var tmp = Paths.Settings + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Json));
            File.Move(tmp, Paths.Settings, overwrite: true);
        }
    }

    /// <summary>Names and brand words (plus the right-hand side of any "heard => meant" fix).</summary>
    public List<string> Words => ParseWords(CustomWords).Concat(Replacements.Select(r => r.To)).ToList();

    /// <summary>"heard => meant" fixes from the same box, applied word-for-word before cleanup.</summary>
    public List<(string From, string To)> Replacements => ParseReplacements(CustomWords);

    static IEnumerable<string> Items(string raw) =>
        raw.Split(['\n', ',', '\r'], StringSplitOptions.RemoveEmptyEntries)
           .Select(s => s.Trim())
           .Where(s => s.Length > 0);

    public static List<string> ParseWords(string raw) => Items(raw).Where(s => !s.Contains("=>")).ToList();

    public static List<(string From, string To)> ParseReplacements(string raw) =>
        Items(raw).Select(item => item.Split("=>").Select(p => p.Trim()).ToArray())
                  .Where(p => p.Length == 2 && p[0].Length > 0 && p[1].Length > 0)
                  .Select(p => (p[0], p[1]))
                  .ToList();

    /// <summary>Whole-word, case-insensitive, one pass over the original text (a fix never feeds
    /// another), longest phrase first.</summary>
    public static string ApplyReplacements(string text, List<(string From, string To)> rules)
    {
        if (rules.Count == 0) return text;
        var map = new Dictionary<string, string>();
        foreach (var r in rules) map[r.From.ToLowerInvariant()] = r.To;   // later rule wins
        var alternation = string.Join("|", map.Keys.OrderByDescending(k => k.Length).Select(Regex.Escape));
        var regex = new Regex($@"(?<![\w'])(?:{alternation})(?![\w'])", RegexOptions.IgnoreCase);
        return regex.Replace(text, m => map.TryGetValue(m.Value.ToLowerInvariant(), out var to) ? to : m.Value);
    }
}

/// <summary>Where the app keeps its data.</summary>
public static class Paths
{
    public static readonly string Support = Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Prosperity Voice"));
    public static readonly string Recordings = Ensure(Path.Combine(Support, "Recordings"));
    public static readonly string Models = Ensure(Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Prosperity Voice", "models"));
    /// <summary>Empty working folder for the AI command-line tools, so they never see a project's files.</summary>
    public static readonly string AiWorkdir = Ensure(Path.Combine(Support, "ai-workdir"));
    /// <summary>Scratch files for tool input and output (outside the AI working folder).</summary>
    public static readonly string AiOutput = Ensure(Path.Combine(Support, "ai-output"));

    public static string Settings => Path.Combine(Support, "settings.json");
    public static string History => Path.Combine(Support, "history.json");
    public static string Log => Path.Combine(Support, "log.txt");
    public static string CurrentRecording => Path.Combine(Recordings, "current.wav");
    public static string LastRecording => Path.Combine(Recordings, "last.wav");

    static string Ensure(string dir)
    {
        Directory.CreateDirectory(dir);
        return dir;
    }
}

/// <summary>Small diagnostic log (never holds transcript text).</summary>
public static class Log
{
    static readonly object Gate = new();

    public static void Write(string message)
    {
        lock (Gate)
        {
            try
            {
                var info = new FileInfo(Paths.Log);
                if (info.Exists && info.Length > 1_000_000) info.Delete();
                File.AppendAllText(Paths.Log, $"{DateTime.UtcNow:yyyy-MM-ddTHH:mm:ssZ} {message}\n");
            }
            catch { /* logging must never break the app */ }
        }
    }
}
