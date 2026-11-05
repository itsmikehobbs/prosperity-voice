package tv.mikehobbs.prosperityvoice

import android.content.Context
import com.google.mlkit.genai.common.FeatureStatus
import com.google.mlkit.genai.prompt.Generation
import com.google.mlkit.genai.prompt.GenerativeModel
import com.google.mlkit.genai.prompt.SystemInstruction
import com.google.mlkit.genai.prompt.TextPart
import com.google.mlkit.genai.prompt.generateContentRequest
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import org.json.JSONArray
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

class CleanException(message: String) : Exception(message)

data class CleanResult(val text: String, val engine: String, val note: String? = null)

enum class Mode(val tag: String, val asset: String) {
    DICTATION("transcript", "dictation-instructions.txt"),
    POLISH("text", "polish-instructions.txt"),
}

/**
 * Port of the Mac and Windows Cleaner: the same instructions (the shared instruction files), the same guards, and
 * the same "ask again when slow" racing for the cloud AI.
 */
object Cleaner {
    const val CLOUD_CHUNK_WORDS = 2500
    /** Gemini Nano has a small context window, so long text is cleaned in pieces (like Apple's on-device model). */
    const val NANO_CHUNK_WORDS = 250
    const val GEMINI_MODEL = "gemini-flash-latest"

    // MARK: Instructions

    fun instructions(context: Context, mode: Mode, words: List<String>): String {
        var s = context.assets.open(mode.asset).bufferedReader().use { it.readText() }.trim()
        if (words.isNotEmpty()) {
            s += "\n\nThe speaker often says these names and terms: " + words.joinToString(", ") +
                ".\nSpeech recognition often mishears them. When a word or phrase clearly sounds like one of them (for example \"My Cobbs\" for \"Mike Hobbs\", \"Cloudflirt\" for \"Cloudflare\"), write that name. Never swap in a name that sounds different, and leave ordinary words alone when they make sense as they are."
        }
        return s
    }

    // MARK: Entry points

    /** Clean a dictation. Never throws; falls back to the raw text. */
    suspend fun cleanDictation(context: Context, raw: String, settings: Settings): CleanResult {
        val engine = settings.engine
        if (engine == Engine.OFF || raw.isBlank()) return CleanResult(raw, "raw")
        return try {
            CleanResult(run(context, raw, Mode.DICTATION, engine, settings), engine.id)
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            Log.write(context, "cleanup failed (${engine.id}): ${e.message}")
            CleanResult(raw, "raw", if (e is CleanException && e.message?.startsWith("The AI changed") == true) "Cleanup skipped" else "Cleanup failed: ${e.message}")
        }
    }

    /** Chunk, clean each piece, and guard each result. A rejected piece keeps its original text. */
    suspend fun run(context: Context, text: String, mode: Mode, engine: Engine, settings: Settings): String {
        val words = settings.words
        val pieces = chunks(text, if (engine == Engine.NANO) NANO_CHUNK_WORDS else CLOUD_CHUNK_WORDS)
        val instructions = instructions(context, mode, words)

        suspend fun cleanPiece(piece: String): String {
            val wrapped = "<${mode.tag}>$piece</${mode.tag}>"
            val raw = if (engine.isCloud) askHedged(engine, wrapped, instructions, settings) else ask(context, engine, wrapped, instructions, settings)
            val out = capitalizeFirst(tidy(raw, mode.tag))
            if (!accepts(mode, piece, out) || addedNames(piece, out, words).isNotEmpty()) throw rejected()
            return out
        }

        if (pieces.size == 1) return cleanPiece(pieces[0])
        val gate = Semaphore(if (engine.isCloud) 3 else 1)
        val outputs = coroutineScope {
            pieces.map { p -> async { gate.withPermit { try { cleanPiece(p) } catch (e: CancellationException) { throw e } catch (e: Exception) { null } } } }.map { it.await() }
        }
        if (outputs.all { it == null }) throw rejected()
        return outputs.mapIndexed { i, o -> o ?: pieces[i] }.joinToString(" ")
    }

    private fun rejected() = CleanException("The AI changed the text too much, so it was skipped.")

    // MARK: Engines

    suspend fun ask(context: Context, engine: Engine, prompt: String, instructions: String, settings: Settings): String = when (engine) {
        Engine.GEMINI -> gemini(prompt, instructions, settings.geminiKey)
        Engine.NANO -> nano(prompt, instructions)
        Engine.OFF -> prompt
    }

    /** The cloud AI usually answers in a few seconds but sometimes stalls. If the first call is
     *  slow, start a second one and use whichever answers first; give up at the hard limit. */
    suspend fun askHedged(engine: Engine, prompt: String, instructions: String, settings: Settings): String {
        val words = wordCount(prompt).toDouble()
        return hedged(engine.label, 7.0 + words / 40, 25.0 + words / 15) {
            gemini(prompt, instructions, settings.geminiKey)
        }
    }

    /** The racing behind askHedged, separate so tests can drive it with fake calls. */
    suspend fun hedged(name: String, hedgeAfter: Double, giveUpAfter: Double, attempt: suspend () -> String): String = coroutineScope {
        val started = System.nanoTime()
        val first = async { runCatching { attempt() } }
        val second = async { delay((hedgeAfter * 1000).toLong()); runCatching { attempt() } }
        val deadline = async { delay((giveUpAfter * 1000).toLong()); null }
        val pending = mutableListOf(first, second)
        var failures = 0
        try {
            while (true) {
                val outcome: Result<String>? = select {
                    pending.forEach { d -> d.onAwait { r -> pending.remove(d); r } }
                    deadline.onAwait { null }
                }
                if (outcome == null) throw CleanException("$name timed out after ${giveUpAfter.toInt()}s")
                outcome.getOrNull()?.let { return@coroutineScope it }
                failures++
                // A quick failure (bad key, offline) won't fix itself: stop now. After the
                // second call has started, wait for it.
                val secondRunning = (System.nanoTime() - started) / 1e9 >= hedgeAfter && failures < 2 && pending.isNotEmpty()
                if (!secondRunning) throw outcome.exceptionOrNull()!!
            }
            @Suppress("UNREACHABLE_CODE") ""
        } finally {
            first.cancel(); second.cancel(); deadline.cancel()
        }
    }

    /** Google's Gemini API with the user's own (free) key. */
    suspend fun gemini(prompt: String, instructions: String, key: String): String {
        if (key.isBlank()) throw CleanException("Add your free Gemini key in Prosperity Voice settings.")
        val body = JSONObject()
            .put("systemInstruction", JSONObject().put("parts", JSONArray().put(JSONObject().put("text", instructions))))
            .put("contents", JSONArray().put(JSONObject().put("role", "user")
                .put("parts", JSONArray().put(JSONObject().put("text", prompt)))))
        val json = runInterruptible(Dispatchers.IO) {
            val conn = URL("https://generativelanguage.googleapis.com/v1beta/models/$GEMINI_MODEL:generateContent").openConnection() as HttpURLConnection
            try {
                conn.requestMethod = "POST"
                conn.connectTimeout = 15000
                conn.readTimeout = 60000
                conn.doOutput = true
                conn.setRequestProperty("Content-Type", "application/json")
                conn.setRequestProperty("x-goog-api-key", key)
                conn.outputStream.use { it.write(body.toString().toByteArray()) }
                val code = conn.responseCode
                val text = (if (code in 200..299) conn.inputStream else conn.errorStream)?.bufferedReader()?.use { it.readText() } ?: ""
                if (code !in 200..299) {
                    val msg = runCatching { JSONObject(text).getJSONObject("error").getString("message") }.getOrNull() ?: "HTTP $code"
                    throw CleanException("Gemini: ${msg.take(160)}")
                }
                text
            } finally { conn.disconnect() }
        }
        return parseGemini(json)
    }

    fun parseGemini(json: String): String {
        val parts = JSONObject(json).optJSONArray("candidates")?.optJSONObject(0)
            ?.optJSONObject("content")?.optJSONArray("parts") ?: throw CleanException("Gemini returned no text.")
        val sb = StringBuilder()
        for (i in 0 until parts.length()) {
            val p = parts.getJSONObject(i)
            if (!p.optBoolean("thought", false)) sb.append(p.optString("text", ""))
        }
        return sb.toString().trim().ifEmpty { throw CleanException("Gemini returned no text.") }
    }

    private var nanoModel: GenerativeModel? = null

    private fun nanoClient() = nanoModel ?: Generation.getClient().also { nanoModel = it }

    /** On-phone status: "available", "downloadable", "downloading", or "unavailable". */
    suspend fun nanoStatus(): String = try {
        when (nanoClient().checkStatus()) {
            FeatureStatus.AVAILABLE -> "available"
            FeatureStatus.DOWNLOADABLE -> "downloadable"
            FeatureStatus.DOWNLOADING -> "downloading"
            else -> "unavailable"
        }
    } catch (e: CancellationException) { throw e } catch (e: Exception) { "unavailable" }

    /** Start Google's one-time download of Gemini Nano onto the phone. */
    suspend fun nanoDownload() { nanoClient().download().collect { } }

    /** Gemini Nano, on the phone (newer Pixel and Galaxy phones). Free and offline. */
    suspend fun nano(prompt: String, instructions: String): String {
        val model = nanoClient()
        when (model.checkStatus()) {
            FeatureStatus.AVAILABLE -> {}
            FeatureStatus.DOWNLOADABLE, FeatureStatus.DOWNLOADING -> throw CleanException("Gemini Nano is still downloading to this phone.")
            else -> throw CleanException("Gemini Nano isn't available on this phone.")
        }
        val useSystem = runCatching { model.isSystemPromptAvailable() }.getOrDefault(false)
        val request = if (useSystem)
            generateContentRequest(SystemInstruction(instructions), TextPart(prompt)) { temperature = 0.2f }
        else
            generateContentRequest(TextPart(instructions + "\n\n" + prompt)) { temperature = 0.2f }
        val text = model.generateContent(request).candidates.firstOrNull()?.text?.trim()
        return text?.ifEmpty { null } ?: throw CleanException("Gemini Nano returned no text.")
    }

    // MARK: Helpers (same behavior as the Mac and Windows apps)

    fun wordCount(s: String) = s.split(Regex("\\s+")).count { it.isNotEmpty() }

    /** Output word count must stay near the input's, to catch answers and cut-offs. */
    fun accepts(mode: Mode, input: String, output: String): Boolean {
        val n = wordCount(input).toDouble()
        val m = wordCount(output).toDouble()
        if (m == 0.0) return false
        if (n < 6) return m <= n + 8
        return if (mode == Mode.DICTATION) m >= n * 0.3 && m <= n * 1.35 + 4 else m >= n * 0.5 && m <= n * 1.6 + 6
    }

    fun capitalizeFirst(s: String): String {
        val i = s.indexOfFirst { it.isLetter() }
        if (i < 0 || !s[i].isLowerCase()) return s
        return s.substring(0, i) + s[i].uppercaseChar() + s.substring(i + 1)
    }

    /** Strip echoed tags, curly quotes, wrapping quotes, and "Here is the cleaned text:" preambles. */
    fun tidy(s: String, tag: String): String {
        var t = s.replace(Regex("</?$tag>"), "").trim()
        t = t.replace('’', '\'').replace('‘', '\'').replace('“', '"').replace('”', '"')
        val firstLine = t.substringBefore('\n')
        val lower = firstLine.lowercase()
        if (firstLine.endsWith(':') && (lower.startsWith("here") || lower.startsWith("sure"))) t = t.substring(firstLine.length).trim()
        if (t.length > 1 && t.startsWith('"') && t.endsWith('"') && !t.substring(1, t.length - 1).contains('"')) t = t.substring(1, t.length - 1)
        return t
    }

    private val commonCapitalized = setOf("I", "OK", "Okay", "Mr", "Mrs", "Ms", "Dr", "AM", "PM")

    /** Capitalized words in the output that were never said (like "Paris" when the speaker asked
     *  about France). A sign the model answered instead of cleaning up. */
    fun addedNames(input: String, output: String, allowed: List<String>): List<String> {
        fun words(s: String) = s.split(Regex("[^\\p{L}]+")).filter { it.isNotEmpty() }
        val known = (words(input) + allowed.flatMap { words(it) }).map { it.lowercase() }.toSet()
        val added = mutableListOf<String>()
        var sentenceStart = true
        for (token in output.split(Regex("\\s+")).filter { it.isNotEmpty() }) {
            val word = token.trim { !it.isLetter() }
            val startsSentence = sentenceStart
            sentenceStart = ".!?:".contains(token.last())
            if (word.length <= 1 || !word[0].isUpperCase() || startsSentence) continue
            for (part in words(word)) if (part.lowercase() !in known && part !in commonCapitalized) added += part
        }
        return added
    }

    /** Split at sentence ends into pieces of at most maxWords (a longer sentence is cut by words). */
    fun chunks(text: String, maxWords: Int): List<String> {
        val trimmed = text.trim()
        if (wordCount(trimmed) <= maxWords) return listOf(trimmed)
        val sentences = mutableListOf<String>()
        val current = StringBuilder()
        for (ch in trimmed) {
            current.append(ch)
            if (".!?\n".contains(ch)) { sentences += current.toString(); current.clear() }
        }
        if (current.isNotEmpty()) sentences += current.toString()
        val pieces = mutableListOf<String>()
        val piece = StringBuilder()
        var count = 0
        fun flush() {
            val joined = piece.toString().trim()
            if (joined.isNotEmpty()) pieces += joined
            piece.clear(); count = 0
        }
        for (sentence in sentences) {
            val n = wordCount(sentence)
            if (n > maxWords) {
                flush()
                val ws = sentence.split(Regex("\\s+")).filter { it.isNotEmpty() }
                ws.chunked(maxWords).forEach { pieces += it.joinToString(" ") }
                continue
            }
            if (count + n > maxWords) flush()
            piece.append(sentence)
            count += n
        }
        flush()
        return pieces
    }
}
