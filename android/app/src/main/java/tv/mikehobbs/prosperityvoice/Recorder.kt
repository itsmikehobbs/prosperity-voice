package tv.mikehobbs.prosperityvoice

import android.annotation.SuppressLint
import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.io.RandomAccessFile
import java.util.concurrent.Executors
import java.util.concurrent.Future
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Records from the microphone at 16 kHz mono. No time limit: while you talk, finished pieces (cut at
 * a pause after about 20 seconds, or at 30 seconds) are transcribed in the background, so stopping
 * only leaves the last piece. The audio is also saved as a WAV for "Retry". Same design as the
 * Windows app.
 */
class Recorder(private val context: Context, private val words: List<String>) {
    companion object {
        const val RATE = Whisper.RATE
        const val SOFT_CHUNK = RATE * 20
        const val HARD_CHUNK = RATE * 30
        const val PAUSE_WINDOW = RATE * 6 / 10

        /** One worker: Whisper runs one piece at a time, in order. */
        private val worker = Executors.newSingleThreadExecutor()

        /** Transcribe a whole recording (Retry, and the test hook), in the same pieces. */
        fun transcribeFile(context: Context, file: File, words: List<String>): String {
            val samples = Wav.read(file)
            if (Whisper.peakDb(samples) < Whisper.SPEECH_THRESHOLD_DB) return ""
            val pieces = mutableListOf<String>()
            var start = 0
            while (start < samples.size) {
                var end = minOf(samples.size, start + HARD_CHUNK)
                if (end < samples.size) {
                    // Prefer a quiet spot between 20 and 30 seconds.
                    var cut = start + SOFT_CHUNK
                    while (cut + PAUSE_WINDOW < end && Whisper.peakDb(samples, cut, cut + PAUSE_WINDOW) >= -38) cut += RATE / 10
                    if (cut + PAUSE_WINDOW < end) end = cut + PAUSE_WINDOW
                }
                pieces += Whisper.transcribe(context, samples.copyOfRange(start, end), words)
                start = end
            }
            return Whisper.normalize(pieces.joinToString(" "))
        }
    }

    /** 0..1 input level, called on the recording thread. */
    var onLevel: ((Float) -> Unit)? = null

    private var record: AudioRecord? = null
    private var thread: Thread? = null
    @Volatile private var running = false
    @Volatile private var cancelled = false
    private val gate = Any()
    private var pending = FloatArray(RATE * 40)
    private var pendingCount = 0
    private val pieces = mutableListOf<Future<String>>()
    private var peakDb = -160.0
    private var wav: Wav.Writer? = null

    @SuppressLint("MissingPermission")   // the app asks for the microphone before the keyboard can record
    fun start() {
        val minBuf = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        val rec = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, max(minBuf, RATE / 5 * 2))
        check(rec.state == AudioRecord.STATE_INITIALIZED) { "The microphone isn't available." }
        record = rec
        wav = Wav.Writer(Settings.recordingFile(context))
        running = true
        rec.startRecording()
        thread = Thread({ loop(rec) }, "pv-recorder").apply { start() }
    }

    private fun loop(rec: AudioRecord) {
        val buf = ShortArray(RATE / 20)   // 50 ms
        while (running) {
            val n = rec.read(buf, 0, buf.size)
            if (n <= 0) continue
            var sum = 0.0
            val floats = FloatArray(n)
            for (i in 0 until n) {
                val s = buf[i] / 32768f
                floats[i] = s
                sum += s * s
            }
            val db = 20 * log10(max(sqrt(sum / n), 1e-5))
            onLevel?.invoke(((db + 55) / 45).toFloat().coerceIn(0f, 1f))
            synchronized(gate) {
                wav?.write(buf, n)
                peakDb = max(peakDb, db)
                append(floats)
                maybeCut()
            }
        }
    }

    private fun append(floats: FloatArray) {
        if (pendingCount + floats.size > pending.size) pending = pending.copyOf(max(pending.size * 2, pendingCount + floats.size))
        System.arraycopy(floats, 0, pending, pendingCount, floats.size)
        pendingCount += floats.size
    }

    /** Caller holds gate. Cut a piece at a pause once it's long enough. */
    private fun maybeCut() {
        if (pendingCount < SOFT_CHUNK) return
        val quiet = Whisper.peakDb(pending, pendingCount - PAUSE_WINDOW, pendingCount) < -38
        if (!quiet && pendingCount < HARD_CHUNK) return
        val chunk = pending.copyOf(pendingCount)
        pendingCount = 0
        pieces += worker.submit<String> { if (cancelled) "" else Whisper.transcribe(context, chunk, words) }
    }

    /** Stop and return the full transcript ("" for silence). Blocks; call off the main thread. */
    fun stop(): String {
        stopAudio()
        val rest: FloatArray
        val all: List<Future<String>>
        val peak: Double
        synchronized(gate) {
            rest = pending.copyOf(pendingCount)
            pendingCount = 0
            all = pieces.toList()
            pieces.clear()
            peak = peakDb
        }
        val tail = worker.submit<String> { Whisper.transcribe(context, rest, words) }
        val texts = (all + tail).map { it.get() }
        return if (peak < Whisper.SPEECH_THRESHOLD_DB) "" else Whisper.normalize(texts.joinToString(" "))
    }

    /** Stop without transcribing. The audio so far stays saved for Retry. */
    fun cancel() {
        cancelled = true
        stopAudio()
        synchronized(gate) {
            pendingCount = 0
            pieces.forEach { it.cancel(false) }
            pieces.clear()
        }
    }

    private fun stopAudio() {
        running = false
        thread?.join(1000)
        thread = null
        record?.let {
            try { it.stop() } catch (_: Exception) {}
            it.release()
        }
        record = null
        synchronized(gate) {
            wav?.close()
            wav = null
        }
    }
}

/** Minimal 16-bit mono WAV reading and writing. */
object Wav {
    class Writer(file: File) {
        private val out = RandomAccessFile(file, "rw").apply { setLength(0); write(ByteArray(44)) }
        private var bytes = 0

        fun write(samples: ShortArray, n: Int) {
            val b = ByteArray(n * 2)
            for (i in 0 until n) {
                b[i * 2] = (samples[i].toInt() and 0xff).toByte()
                b[i * 2 + 1] = (samples[i].toInt() shr 8 and 0xff).toByte()
            }
            out.write(b)
            bytes += b.size
        }

        fun close() {
            out.seek(0)
            out.write(header(bytes))
            out.close()
        }
    }

    fun header(dataBytes: Int, rate: Int = Whisper.RATE): ByteArray {
        val h = java.nio.ByteBuffer.allocate(44).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        h.put("RIFF".toByteArray()); h.putInt(36 + dataBytes); h.put("WAVE".toByteArray())
        h.put("fmt ".toByteArray()); h.putInt(16); h.putShort(1); h.putShort(1)
        h.putInt(rate); h.putInt(rate * 2); h.putShort(2); h.putShort(16)
        h.put("data".toByteArray()); h.putInt(dataBytes)
        return h.array()
    }

    /** Read a 16-bit PCM WAV (mono or stereo, any rate) as 16 kHz mono floats. */
    fun read(file: File): FloatArray {
        val all = file.readBytes()
        val buf = java.nio.ByteBuffer.wrap(all).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        var channels = 1
        var rate = Whisper.RATE
        var pos = 12
        var dataStart = -1
        var dataLen = 0
        while (pos + 8 <= all.size) {
            val id = String(all, pos, 4)
            val len = buf.getInt(pos + 4)
            if (id == "fmt ") {
                channels = buf.getShort(pos + 10).toInt()
                rate = buf.getInt(pos + 12)
            } else if (id == "data") {
                dataStart = pos + 8
                dataLen = minOf(len, all.size - dataStart)
                break
            }
            pos += 8 + len + (len and 1)
        }
        require(dataStart >= 0) { "Not a WAV file" }
        val frames = dataLen / 2 / channels
        val mono = FloatArray(frames) { f ->
            var s = 0f
            for (c in 0 until channels) s += buf.getShort(dataStart + (f * channels + c) * 2) / 32768f
            s / channels
        }
        if (rate == Whisper.RATE) return mono
        // Linear resample to 16 kHz.
        val outLen = (frames.toLong() * Whisper.RATE / rate).toInt()
        return FloatArray(outLen) { i ->
            val x = i.toDouble() * rate / Whisper.RATE
            val i0 = x.toInt().coerceAtMost(frames - 1)
            val i1 = (i0 + 1).coerceAtMost(frames - 1)
            val t = (x - i0).toFloat()
            mono[i0] * (1 - t) + mono[i1] * t
        }
    }
}
