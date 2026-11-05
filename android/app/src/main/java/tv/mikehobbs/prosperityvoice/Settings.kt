package tv.mikehobbs.prosperityvoice

import android.content.Context
import android.content.SharedPreferences
import java.io.File

/** Which AI cleans up the words. Same choices idea as the Mac and Windows apps. */
enum class Engine(val id: String, val label: String) {
    NANO("nano", "Gemini Nano (on this phone, free)"),
    GEMINI("gemini", "Gemini (free key from Google)"),
    OFF("off", "Off (paste exactly what I said)");

    val isCloud get() = this == GEMINI

    companion object {
        fun of(id: String?) = entries.firstOrNull { it.id == id }
    }
}

/** Settings live in the app's private storage. */
class Settings(context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** Null until the user (or first-run setup) picks one. */
    var engineOrNull: Engine?
        get() = Engine.of(prefs.getString("engine", null))
        set(v) = prefs.edit().putString("engine", v?.id).apply()
    var engine: Engine
        get() = engineOrNull ?: Engine.OFF
        set(v) { engineOrNull = v }

    var geminiKey: String
        get() = prefs.getString("geminiKey", "") ?: ""
        set(v) = prefs.edit().putString("geminiKey", v.trim()).apply()

    /** "Words to spell right": names and terms, plus "heard => meant" fix lines. */
    var customWords: String
        get() = prefs.getString("customWords", "") ?: ""
        set(v) = prefs.edit().putString("customWords", v).apply()

    var keepHistory: Boolean
        get() = prefs.getBoolean("keepHistory", true)
        set(v) = prefs.edit().putBoolean("keepHistory", v).apply()

    val replacements get() = TextRules.parseReplacements(customWords)
    val words get() = TextRules.parseWords(customWords) + replacements.map { it.second }

    companion object {
        fun modelFile(context: Context) = File(context.filesDir, "ggml-base.en.bin")
        fun recordingFile(context: Context) = File(context.filesDir, "last-recording.wav")
    }
}

/** Word list and "heard => meant" fixes, the same rules as the other apps. */
object TextRules {
    private fun items(raw: String) =
        raw.split('\n', ',', '\r').map { it.trim() }.filter { it.isNotEmpty() }

    fun parseWords(raw: String) = items(raw).filter { !it.contains("=>") }

    fun parseReplacements(raw: String): List<Pair<String, String>> =
        items(raw).map { item -> item.split("=>").map { it.trim() } }
            .filter { it.size == 2 && it[0].isNotEmpty() && it[1].isNotEmpty() }
            .map { it[0] to it[1] }

    /** Whole-word, case-insensitive, one pass (a fix never feeds another), longest phrase first. */
    fun applyReplacements(text: String, rules: List<Pair<String, String>>): String {
        if (rules.isEmpty()) return text
        val map = LinkedHashMap<String, String>()
        for ((from, to) in rules) map[from.lowercase()] = to   // later rule wins
        val alternation = map.keys.sortedByDescending { it.length }.joinToString("|") { Regex.escape(it) }
        val regex = Regex("(?<![\\w'])(?:$alternation)(?![\\w'])", RegexOption.IGNORE_CASE)
        return regex.replace(text) { m -> map[m.value.lowercase()] ?: m.value }
    }
}
