using System.Text.Json;

namespace ProsperityVoice;

public sealed class HistoryEntry
{
    public Guid Id { get; set; } = Guid.NewGuid();
    public DateTime Date { get; set; } = DateTime.UtcNow;
    /// <summary>"dictation" or "polish"</summary>
    public string Kind { get; set; } = "dictation";
    /// <summary>What was heard (dictation) or the original selection (polish).</summary>
    public string Original { get; set; } = "";
    /// <summary>What was pasted or returned.</summary>
    public string Text { get; set; } = "";
    public string Engine { get; set; } = "raw";
    public string? App { get; set; }
    public double? Seconds { get; set; }
    public bool Pasted { get; set; }
}

/// <summary>Saved dictations and polishes, newest first, in one JSON file.</summary>
public sealed class HistoryStore
{
    readonly object gate = new();
    readonly string path;
    List<HistoryEntry> entries = [];

    public event Action? Changed;

    public HistoryStore(string? path = null)
    {
        this.path = path ?? Paths.History;
        Load();
    }

    public IReadOnlyList<HistoryEntry> Entries
    {
        get { lock (gate) return entries.ToList(); }
    }

    void Load()
    {
        if (!File.Exists(path)) return;
        try
        {
            entries = JsonSerializer.Deserialize<List<HistoryEntry>>(File.ReadAllText(path)) ?? [];
        }
        catch
        {
            // Keep a damaged file aside instead of overwriting it.
            var backup = Path.ChangeExtension(path, $"damaged-{DateTimeOffset.UtcNow.ToUnixTimeSeconds()}.json");
            try { File.Move(path, backup); } catch { }
            entries = [];
        }
    }

    public void Add(HistoryEntry e)
    {
        lock (gate) { entries.Insert(0, e); Save(); }
        Changed?.Invoke();
    }

    public void Update(Guid id, Action<HistoryEntry> change)
    {
        lock (gate)
        {
            var e = entries.FirstOrDefault(x => x.Id == id);
            if (e == null) return;
            change(e);
            Save();
        }
        Changed?.Invoke();
    }

    public void Delete(Guid id)
    {
        lock (gate) { entries.RemoveAll(x => x.Id == id); Save(); }
        Changed?.Invoke();
    }

    public void Clear()
    {
        lock (gate) { entries.Clear(); Save(); }
        Changed?.Invoke();
    }

    void Save()
    {
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(entries, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, path, overwrite: true);
    }
}
