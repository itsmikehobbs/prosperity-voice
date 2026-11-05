package tv.mikehobbs.prosperityvoice

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant

/** Diagnostic log. Never holds what was said. */
object Log {
    fun write(context: Context, message: String) {
        try {
            val f = File(context.filesDir, "log.txt")
            if (f.length() > 512 * 1024) f.writeText(f.readLines().takeLast(2000).joinToString("\n") + "\n")
            f.appendText("${Instant.now()} $message\n")
        } catch (_: Exception) {}
        android.util.Log.i("ProsperityVoice", message)
    }
}

data class HistoryEntry(val time: Long, val original: String, val text: String, val engine: String)

/** Past dictations, newest first, saved only on the phone. */
class History(context: Context) {
    private val file = File(context.filesDir, "history.json")

    fun all(): List<HistoryEntry> = try {
        val arr = JSONArray(file.readText())
        (0 until arr.length()).map { arr.getJSONObject(it) }.map {
            HistoryEntry(it.getLong("time"), it.getString("original"), it.getString("text"), it.getString("engine"))
        }
    } catch (_: Exception) { emptyList() }

    @Synchronized
    fun add(entry: HistoryEntry) {
        val list = listOf(entry) + all().take(199)
        val arr = JSONArray()
        list.forEach { arr.put(JSONObject().put("time", it.time).put("original", it.original).put("text", it.text).put("engine", it.engine)) }
        file.writeText(arr.toString())
    }

    fun clear() { file.delete() }
}
