package tv.mikehobbs.prosperityvoice

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.inputmethodservice.InputMethodService
import android.os.Build
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

/**
 * The Prosperity Voice keyboard. Tap the mic, talk as long as you like, tap again: your words are
 * cleaned up and typed into the text box. No time limit.
 */
class VoiceKeyboard : InputMethodService() {
    private enum class Phase { IDLE, RECORDING, WORKING }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var settings: Settings
    private lateinit var history: History
    private var phase = Phase.IDLE
    private var recorder: Recorder? = null
    private var job: Job? = null
    private var lastInserted: String? = null

    private lateinit var status: TextView
    private lateinit var mic: Button
    private lateinit var level: View
    private lateinit var cancelButton: Button

    /** Test hook (debug builds only): transcribe a WAV as if it were just recorded. */
    private val debugReceiver = object : BroadcastReceiver() {
        override fun onReceive(c: Context, intent: Intent) {
            val path = intent.getStringExtra("wav") ?: return
            processFile(File(path))
        }
    }

    override fun onCreate() {
        super.onCreate()
        settings = Settings(this)
        history = History(this)
        if (BuildConfigCompat.isDebuggable(this)) {
            val filter = IntentFilter("tv.mikehobbs.prosperityvoice.DEBUG_DICTATE")
            if (Build.VERSION.SDK_INT >= 33) registerReceiver(debugReceiver, filter, RECEIVER_EXPORTED)
            else @Suppress("UnspecifiedRegisterReceiverFlag") registerReceiver(debugReceiver, filter)
        }
    }

    override fun onDestroy() {
        recorder?.cancel()
        scope.cancel()
        runCatching { unregisterReceiver(debugReceiver) }
        super.onDestroy()
    }

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    private fun dark() = (resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK) ==
        android.content.res.Configuration.UI_MODE_NIGHT_YES

    override fun onCreateInputView(): View {
        val bg = if (dark()) Color.rgb(32, 33, 36) else Color.rgb(236, 238, 241)
        val fg = if (dark()) Color.WHITE else Color.rgb(32, 33, 36)
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setBackgroundColor(bg)
            setPadding(dp(12), dp(10), dp(12), dp(12))
        }
        status = TextView(this).apply {
            setTextColor(fg)
            textSize = 15f
            gravity = Gravity.CENTER
            minLines = 2
        }
        root.addView(status, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT))

        level = View(this).apply { background = GradientDrawable().apply { cornerRadius = dp(3).toFloat(); setColor(Color.rgb(220, 60, 60)) } }
        val levelRow = LinearLayout(this).apply { gravity = Gravity.CENTER; addView(level, LinearLayout.LayoutParams(0, dp(6))) }
        root.addView(levelRow, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(12)))

        mic = Button(this).apply {
            textSize = 18f
            isAllCaps = false
            setTextColor(Color.WHITE)
            setOnClickListener { onMic() }
        }
        root.addView(mic, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(72)).apply { topMargin = dp(4) })

        val row = LinearLayout(this).apply { orientation = LinearLayout.HORIZONTAL }
        fun key(label: String, weight: Float, action: () -> Unit) = Button(this).apply {
            text = label
            isAllCaps = false
            textSize = 15f
            setOnClickListener { action() }
            row.addView(this, LinearLayout.LayoutParams(0, dp(52), weight))
        }
        key("⌨︎", 1f) { switchKeyboard() }.contentDescription = "Switch keyboard"
        cancelButton = key("Cancel", 1.4f) { cancel() }
        key("Retry", 1.4f) { retry() }
        key("space", 2f) { currentInputConnection?.commitText(" ", 1) }
        key("⌫", 1f) { sendDownUpKeyEvents(KeyEvent.KEYCODE_DEL) }.contentDescription = "Delete"
        key("⏎", 1f) { enter() }.contentDescription = "Enter"
        root.addView(row, LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, LinearLayout.LayoutParams.WRAP_CONTENT).apply { topMargin = dp(8) })

        render()
        return root
    }

    override fun onStartInputView(info: EditorInfo?, restarting: Boolean) {
        super.onStartInputView(info, restarting)
        if (::status.isInitialized && phase == Phase.IDLE) render()
    }

    override fun onFinishInputView(finishingInput: Boolean) {
        // Keyboard hidden while recording (switched apps, closed the field): keep the audio for Retry.
        if (phase == Phase.RECORDING) cancel(quietly = true)
        super.onFinishInputView(finishingInput)
    }

    private fun render(message: String? = null) {
        val (label, color) = when (phase) {
            Phase.IDLE -> "🎤  Tap to talk" to Color.rgb(37, 99, 235)
            Phase.RECORDING -> "■  Tap when done" to Color.rgb(220, 38, 38)
            Phase.WORKING -> "Cleaning up…" to Color.GRAY
        }
        mic.text = label
        mic.isEnabled = phase != Phase.WORKING
        mic.background = GradientDrawable().apply { cornerRadius = dp(36).toFloat(); setColor(color) }
        cancelButton.isEnabled = phase != Phase.IDLE
        level.visibility = if (phase == Phase.RECORDING) View.VISIBLE else View.INVISIBLE
        // Keep the screen on while recording, so a long dictation isn't cut off by the screen timeout.
        mic.keepScreenOn = phase == Phase.RECORDING
        status.text = message ?: when (phase) {
            Phase.IDLE -> setupProblem() ?: "Talk as long as you like. No time limit."
            Phase.RECORDING -> "Listening… talk as long as you like."
            Phase.WORKING -> if (settings.engine == Engine.OFF) "Turning your words into text…" else "Cleaning up your words…"
        }
    }

    private fun setupProblem(): String? = when {
        checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ->
            "Open the Prosperity Voice app to allow the microphone."
        !Whisper.modelReady(this) -> "Open the Prosperity Voice app to download the speech model."
        else -> null
    }

    private fun onMic() {
        when (phase) {
            Phase.IDLE -> start()
            Phase.RECORDING -> finish()
            Phase.WORKING -> {}
        }
    }

    private fun start() {
        setupProblem()?.let { problem ->
            render(problem)
            startActivity(Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
            return
        }
        val rec = Recorder(this, settings.words)
        rec.onLevel = { v -> level.post { (level.layoutParams as LinearLayout.LayoutParams).let { it.width = (dp(240) * v).toInt().coerceAtLeast(dp(6)); level.layoutParams = it } } }
        try {
            rec.start()
        } catch (e: Exception) {
            Log.write(this, "recording failed: ${e.message}")
            render("Couldn't start the microphone: ${e.message}")
            return
        }
        recorder = rec
        phase = Phase.RECORDING
        Log.write(this, "start engine=${settings.engine.id}")
        render()
    }

    private fun finish() {
        val rec = recorder ?: return
        recorder = null
        phase = Phase.WORKING
        render()
        job = scope.launch {
            val started = System.currentTimeMillis()
            val raw = try {
                withContext(Dispatchers.Default) { rec.stop() }
            } catch (e: Exception) {
                Log.write(this@VoiceKeyboard, "transcription error: ${e.message}")
                phase = Phase.IDLE
                render("Speech recognition failed: ${e.message}. Tap Retry to try again.")
                return@launch
            }
            deliver(raw, started)
        }
    }

    /** Retry (or the test hook): transcribe a saved recording, then clean and type it. */
    private fun processFile(file: File) {
        if (phase != Phase.IDLE || !file.exists()) {
            if (::status.isInitialized && !file.exists()) render("Nothing to retry yet.")
            return
        }
        phase = Phase.WORKING
        render()
        job = scope.launch {
            val started = System.currentTimeMillis()
            val raw = try {
                withContext(Dispatchers.Default) { Recorder.transcribeFile(this@VoiceKeyboard, file, settings.words) }
            } catch (e: Exception) {
                Log.write(this@VoiceKeyboard, "transcription error: ${e.message}")
                phase = Phase.IDLE
                render("Speech recognition failed: ${e.message}")
                return@launch
            }
            deliver(raw, started)
        }
    }

    private suspend fun deliver(raw: String, started: Long) {
        if (raw.isBlank()) {
            phase = Phase.IDLE
            render("Didn't catch any words. Tap Retry to try the recording again.")
            return
        }
        val fixed = TextRules.applyReplacements(raw, settings.replacements)
        val heard = System.currentTimeMillis()
        val result = Cleaner.cleanDictation(this, fixed, settings)
        val ic = currentInputConnection
        val before = ic?.getTextBeforeCursor(1, 0)?.toString() ?: ""
        val text = (if (before.isNotEmpty() && !before.last().isWhitespace()) " " else "") + result.text
        val pasted = ic?.commitText(text, 1) == true
        if (!pasted) copyToClipboard(result.text)
        lastInserted = text
        if (settings.keepHistory) history.add(HistoryEntry(System.currentTimeMillis(), raw, result.text, result.engine))
        Log.write(this, "deliver words=${Cleaner.wordCount(raw)}→${Cleaner.wordCount(result.text)} engine=${result.engine} " +
            "speech=${(heard - started) / 100 / 10.0}s cleanup=${(System.currentTimeMillis() - heard) / 100 / 10.0}s outcome=${if (pasted) "typed" else "copied"} note=${result.note ?: "-"}")
        phase = Phase.IDLE
        val base = if (pasted) "Done." else "Copied. Tap and hold in a text box, then Paste."
        render(result.note?.let { "$base ($it)" } ?: base)
    }

    private fun copyToClipboard(text: String) {
        val cm = getSystemService(android.content.ClipboardManager::class.java)
        cm?.setPrimaryClip(android.content.ClipData.newPlainText("Prosperity Voice", text))
    }

    private fun cancel(quietly: Boolean = false) {
        when (phase) {
            Phase.RECORDING -> { recorder?.cancel(); recorder = null; Log.write(this, "cancel while recording") }
            Phase.WORKING -> job?.cancel()
            Phase.IDLE -> return
        }
        phase = Phase.IDLE
        if (!quietly && ::status.isInitialized) render("Cancelled. Your recording is saved: tap Retry to use it.")
    }

    private fun retry() = processFile(Settings.recordingFile(this))

    private fun enter() {
        val info = currentInputEditorInfo
        val action = info?.imeOptions?.and(EditorInfo.IME_MASK_ACTION) ?: EditorInfo.IME_ACTION_NONE
        if (action != EditorInfo.IME_ACTION_NONE && action != EditorInfo.IME_ACTION_UNSPECIFIED &&
            info?.imeOptions?.and(EditorInfo.IME_FLAG_NO_ENTER_ACTION) == 0) {
            currentInputConnection?.performEditorAction(action)
        } else {
            sendDownUpKeyEvents(KeyEvent.KEYCODE_ENTER)
        }
    }

    private fun switchKeyboard() {
        if (!switchToPreviousInputMethod()) {
            getSystemService(InputMethodManager::class.java)?.showInputMethodPicker()
        }
    }
}

object BuildConfigCompat {
    fun isDebuggable(context: Context) =
        (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0
}
