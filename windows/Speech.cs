using NAudio.Wave;
using Whisper.net;
using Whisper.net.Ggml;

namespace ProsperityVoice;

/// <summary>
/// Local speech to text with Whisper (whisper.cpp). The model downloads once on first use.
/// Whisper isn't thread-safe per processor, so all transcription goes through one lock.
/// </summary>
public static class Whisperer
{
    public const GgmlType ModelType = GgmlType.BaseEn;
    public static string ModelPath => Path.Combine(Paths.Models, "ggml-base.en.bin");

    static readonly SemaphoreSlim Gate = new(1, 1);
    static WhisperFactory? factory;

    public static bool ModelReady => File.Exists(ModelPath);

    /// <summary>Download the model if needed. Safe to call repeatedly.</summary>
    public static async Task EnsureModel(IProgress<string>? status = null)
    {
        if (ModelReady) return;
        status?.Report("Downloading the speech model (about 140 MB, one time)…");
        var tmp = ModelPath + ".download";
        await using (var model = await WhisperGgmlDownloader.Default.GetGgmlModelAsync(ModelType))
        await using (var file = File.Create(tmp))
            await model.CopyToAsync(file);
        File.Move(tmp, ModelPath, overwrite: true);
        Log.Write("speech model downloaded");
    }

    static WhisperFactory Factory() => factory ??= WhisperFactory.FromPath(ModelPath);

    /// <summary>Transcribe 16 kHz mono float samples. The word list nudges spelling of names.</summary>
    public static async Task<string> Transcribe(float[] samples, List<string> words, CancellationToken token = default)
    {
        if (samples.Length < 16000 / 4) return "";
        await EnsureModel();
        await Gate.WaitAsync(token);
        try
        {
            var builder = Factory().CreateBuilder()
                .WithLanguage("en")
                .WithThreads(Math.Max(2, Environment.ProcessorCount / 2))
                .WithNoSpeechThreshold(0.6f);
            if (words.Count > 0) builder = builder.WithPrompt(string.Join(", ", words) + ".");
            await using var processor = builder.Build();
            var parts = new List<string>();
            await foreach (var seg in processor.ProcessAsync(samples, token))
            {
                var t = seg.Text.Trim();
                if (t.Length == 0 || IsNoise(t)) continue;
                parts.Add(t);
            }
            return Normalize(string.Join(" ", parts));
        }
        finally { Gate.Release(); }
    }

    /// <summary>Whisper's markers for silence and sounds, which should never be pasted.</summary>
    static bool IsNoise(string t) =>
        (t.StartsWith('[') && t.EndsWith(']')) || (t.StartsWith('(') && t.EndsWith(')'));

    public static string Normalize(string text) =>
        System.Text.RegularExpressions.Regex.Replace(text, @"[ \t]+", " ").Trim();

    /// <summary>Read a WAV file as 16 kHz mono floats (any input format).</summary>
    public static float[] ReadWav(string path)
    {
        using var reader = new AudioFileReader(path);
        ISampleProvider source = reader;
        if (source.WaveFormat.Channels > 1) source = source.ToMono();
        if (source.WaveFormat.SampleRate != 16000)
            source = new NAudio.Wave.SampleProviders.WdlResamplingSampleProvider(source, 16000);
        var all = new List<float>();
        var buf = new float[16000];
        int n;
        while ((n = source.Read(buf.AsSpan())) > 0) all.AddRange(buf.AsSpan(0, n).ToArray());
        return all.ToArray();
    }

    /// <summary>Loudest 100 ms of the audio, in dBFS. Silence makes Whisper invent short phrases
    /// ("Thank you."), so a recording that never gets loud counts as no speech.</summary>
    public static double PeakDb(ReadOnlySpan<float> samples)
    {
        double peak = -160;
        const int win = 1600;
        for (var i = 0; i + win <= samples.Length; i += win)
        {
            double sum = 0;
            for (var j = i; j < i + win; j++) sum += samples[j] * samples[j];
            var db = 20 * Math.Log10(Math.Max(Math.Sqrt(sum / win), 1e-5));
            peak = Math.Max(peak, db);
        }
        return peak;
    }

    public const double SpeechThresholdDb = -50;
}

/// <summary>
/// Records from the default microphone at 16 kHz mono. While you talk, finished pieces (split at a
/// pause after about 20 seconds, or at 30 seconds) are transcribed in the background, so letting go
/// only leaves the last piece. No time limit. Audio is also saved as a WAV for "Retry".
/// </summary>
public sealed class Recorder : IDisposable
{
    const int Rate = 16000;
    const int SoftChunk = Rate * 20, HardChunk = Rate * 30, PauseWindow = Rate * 6 / 10;

    WaveIn? wave;
    WaveFileWriter? writer;
    readonly object gate = new();
    readonly List<float> pending = [];
    readonly List<Task<string>> pieces = [];
    double peakDb = -160;
    List<string> words = [];
    CancellationTokenSource cts = new();

    /// <summary>0…1 input level, raised on a background thread.</summary>
    public event Action<float>? Level;

    public void Start(List<string> words)
    {
        this.words = words;
        cts = new CancellationTokenSource();
        try { File.Delete(Paths.CurrentRecording); } catch { }
        wave = new WaveIn { WaveFormat = new WaveFormat(Rate, 16, 1), BufferMilliseconds = 50 };
        writer = new WaveFileWriter(Paths.CurrentRecording, wave.WaveFormat);
        wave.DataAvailable += OnData;
        wave.StartRecording();
    }

    void OnData(object? sender, WaveInEventArgs e)
    {
        var count = e.BytesRecorded / 2;
        var samples = new float[count];
        double sum = 0;
        for (var i = 0; i < count; i++)
        {
            var s = BitConverter.ToInt16(e.Buffer, i * 2) / 32768f;
            samples[i] = s;
            sum += s * s;
        }
        var db = 20 * Math.Log10(Math.Max(Math.Sqrt(sum / Math.Max(count, 1)), 1e-5));
        Level?.Invoke((float)Math.Clamp((db + 55) / 45, 0, 1));
        lock (gate)
        {
            writer?.Write(e.Buffer, 0, e.BytesRecorded);
            peakDb = Math.Max(peakDb, db);
            pending.AddRange(samples);
            MaybeCut();
        }
    }

    /// <summary>Caller holds gate. Cut a piece at a pause once it's long enough.</summary>
    void MaybeCut()
    {
        if (pending.Count < SoftChunk) return;
        var tail = System.Runtime.InteropServices.CollectionsMarshal.AsSpan(pending)[^PauseWindow..];
        var quiet = Whisperer.PeakDb(tail) < -38;
        if (!quiet && pending.Count < HardChunk) return;
        var chunk = pending.ToArray();
        pending.Clear();
        var w = words;
        var token = cts.Token;
        pieces.Add(Task.Run(() => Whisperer.Transcribe(chunk, w, token)));
    }

    /// <summary>Stop and return the full transcript ("" for silence).</summary>
    public async Task<string> Stop()
    {
        StopAudio();
        float[] rest;
        List<Task<string>> all;
        double peak;
        lock (gate)
        {
            rest = pending.ToArray();
            pending.Clear();
            all = pieces.ToList();
            pieces.Clear();
            peak = peakDb;
        }
        var tail = Whisperer.Transcribe(rest, words, cts.Token);
        var texts = await Task.WhenAll(all.Append(tail));
        Log.Write($"recording peak {peak:0} dBFS, {all.Count + 1} piece(s)");
        return peak < Whisperer.SpeechThresholdDb ? "" : Whisperer.Normalize(string.Join(" ", texts));
    }

    /// <summary>Stop without transcribing. The audio captured so far stays on disk.</summary>
    public void Cancel()
    {
        cts.Cancel();
        StopAudio();
        lock (gate) { pending.Clear(); pieces.Clear(); }
    }

    void StopAudio()
    {
        if (wave != null)
        {
            wave.DataAvailable -= OnData;
            try { wave.StopRecording(); } catch { }
            wave.Dispose();
            wave = null;
        }
        lock (gate)
        {
            writer?.Dispose();
            writer = null;
        }
    }

    public static bool HasMicrophone => WaveIn.DeviceCount > 0;

    public void Dispose() => Cancel();
}
