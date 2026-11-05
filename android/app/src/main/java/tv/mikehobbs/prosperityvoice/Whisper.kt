package tv.mikehobbs.prosperityvoice

import android.content.Context
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Local speech to text with Whisper (whisper.cpp), the same model as the Windows app. The model
 * downloads once. One model context is shared, and calls are serialized (whisper isn't thread-safe
 * per context).
 */
object Whisper {
    /** Loaded on first use, so the plain text helpers work in JVM unit tests. */
    private val native by lazy { System.loadLibrary("pvwhisper") }

    @JvmStatic private external fun nativeInit(path: String): Long
    @JvmStatic private external fun nativeFree(handle: Long)
    @JvmStatic private external fun nativeTranscribe(handle: Long, audio: FloatArray, prompt: String?, threads: Int): String

    const val MODEL_URL = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
    const val MODEL_BYTES = 147_964_211L
    const val RATE = 16000
    /** A recording that never gets louder than this has no speech (silence makes Whisper invent "Thank you."). */
    const val SPEECH_THRESHOLD_DB = -50.0

    private var handle = 0L
    private val lock = Any()

    fun modelReady(context: Context) = Settings.modelFile(context).let { it.exists() && it.length() == MODEL_BYTES }

    /** Download the model (about 150 MB, one time). Reports 0..1 progress. Safe to call again. */
    fun download(context: Context, progress: (Float) -> Unit) {
        val dest = Settings.modelFile(context)
        if (modelReady(context)) return
        val tmp = File(dest.path + ".download")
        var url = URL(MODEL_URL)
        var conn: HttpURLConnection
        var redirects = 0
        while (true) {
            conn = url.openConnection() as HttpURLConnection
            conn.instanceFollowRedirects = false
            conn.connectTimeout = 20000
            conn.readTimeout = 30000
            val code = conn.responseCode
            if (code in 300..399 && redirects++ < 5) {
                url = URL(url, conn.getHeaderField("Location"))
                conn.disconnect()
                continue
            }
            if (code != 200) throw IllegalStateException("Download failed (HTTP $code)")
            break
        }
        conn.inputStream.use { input ->
            tmp.outputStream().use { out ->
                val buf = ByteArray(1 shl 16)
                var done = 0L
                while (true) {
                    val n = input.read(buf)
                    if (n < 0) break
                    out.write(buf, 0, n)
                    done += n
                    progress((done.toFloat() / MODEL_BYTES).coerceAtMost(1f))
                }
            }
        }
        if (tmp.length() != MODEL_BYTES) {
            tmp.delete()
            throw IllegalStateException("The download was incomplete. Try again.")
        }
        tmp.renameTo(dest)
    }

    /** Transcribe 16 kHz mono floats. The word list nudges Whisper toward the right spellings. */
    fun transcribe(context: Context, samples: FloatArray, words: List<String>): String {
        if (samples.size < RATE / 4) return ""
        synchronized(lock) {
            native
            if (handle == 0L) {
                check(modelReady(context)) { "The speech model isn't downloaded yet. Open Prosperity Voice to download it." }
                handle = nativeInit(Settings.modelFile(context).path)
                check(handle != 0L) { "The speech model couldn't load." }
            }
            val prompt = if (words.isEmpty()) null else words.joinToString(", ") + "."
            val threads = max(2, minOf(4, Runtime.getRuntime().availableProcessors() - 2))
            val raw = nativeTranscribe(handle, samples, prompt, threads)
            return normalize(raw.lines().map { it.trim() }.filter { it.isNotEmpty() && !isNoise(it) }.joinToString(" "))
        }
    }

    /** Whisper's markers for silence and sounds ("[BLANK_AUDIO]", "(music)"), never pasted. */
    fun isNoise(t: String) = (t.startsWith('[') && t.endsWith(']')) || (t.startsWith('(') && t.endsWith(')'))

    fun normalize(text: String) = text.replace(Regex("[ \t]+"), " ").trim()

    /** Loudest 100 ms of the audio, in dBFS. */
    fun peakDb(samples: FloatArray, from: Int = 0, to: Int = samples.size): Double {
        var peak = -160.0
        val win = 1600
        var i = from
        while (i + win <= to) {
            var sum = 0.0
            for (j in i until i + win) sum += samples[j] * samples[j]
            peak = max(peak, 20 * log10(max(sqrt(sum / win), 1e-5)))
            i += win
        }
        return peak
    }
}
