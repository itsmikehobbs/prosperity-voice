package tv.mikehobbs.prosperityvoice

import android.Manifest
import android.app.Activity
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.graphics.Typeface
import android.net.Uri
import android.os.Bundle
import android.provider.Settings as SystemSettings
import android.text.Editable
import android.text.InputType
import android.text.TextWatcher
import android.util.TypedValue
import android.view.View
import android.view.WindowInsets
import android.view.inputmethod.InputMethodManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.RadioButton
import android.widget.RadioGroup
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.text.DateFormat
import java.util.Date

/** Setup and settings: microphone, keyboard, speech model, cleanup AI, words, history. */
class MainActivity : Activity() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private lateinit var settings: Settings
    /** Rebuilt on every change: setup steps and settings. */
    private lateinit var content: LinearLayout
    /** Built once, so a rebuild never wipes what was dictated into it. */
    private lateinit var tryIt: LinearLayout
    /** Rebuilt with the rest: cleanup AI and words. */
    private lateinit var settingsBox: LinearLayout
    /** Rebuilt with the rest. */
    private lateinit var historyBox: LinearLayout
    private var downloading = false
    private var downloadProgress = 0f
    private var nanoStatus = "checking"

    private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        settings = Settings(this)
        content = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        tryIt = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        settingsBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        historyBox = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(24), dp(20), dp(40))
            // The try-it box sits right after the setup steps, so it stays above the keyboard.
            addView(content); addView(tryIt); addView(settingsBox); addView(historyBox)
        }
        tryIt.addView(heading("Try it"))
        tryIt.addView(body("Tap in this box, make sure the Prosperity Voice keyboard is showing, then tap the mic and talk."))
        tryIt.addView(EditText(this).apply {
            hint = "Your words appear here"
            minLines = 3
            contentDescription = "Try it here"
        })
        val scroll = ScrollView(this).apply { addView(page) }
        // Android 15+ draws apps edge to edge: pad for the status bar, the navigation bar, and the
        // keyboard, so the box being typed in can scroll into view above the keyboard.
        scroll.setOnApplyWindowInsetsListener { v, insets ->
            val bars = insets.getInsets(WindowInsets.Type.systemBars())
            val ime = insets.getInsets(WindowInsets.Type.ime())
            v.setPadding(bars.left, bars.top, bars.right, maxOf(bars.bottom, ime.bottom))
            v.findFocus()?.let { f -> v.post { f.requestRectangleOnScreen(android.graphics.Rect(0, 0, f.width, f.height), false) } }
            insets
        }
        actionBar?.hide()
        setContentView(scroll)
        scope.launch {
            nanoStatus = Cleaner.nanoStatus()
            // First run: use the phone's own free AI if it has one.
            if (settings.engineOrNull == null && nanoStatus != "unavailable") settings.engine = Engine.NANO
            build()
        }
        build()
    }

    override fun onResume() {
        super.onResume()
        build()
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        build()
    }

    private fun micAllowed() = checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun keyboardEnabled() = getSystemService(InputMethodManager::class.java)
        .enabledInputMethodList.any { it.packageName == packageName }

    private fun keyboardSelected() =
        SystemSettings.Secure.getString(contentResolver, SystemSettings.Secure.DEFAULT_INPUT_METHOD)?.startsWith(packageName) == true

    private fun heading(text: String) = TextView(this).apply {
        this.text = text
        textSize = 18f
        setTypeface(typeface, Typeface.BOLD)
        setPadding(0, dp(22), 0, dp(6))
    }

    private fun body(text: String) = TextView(this).apply {
        this.text = text
        textSize = 15f
        setPadding(0, 0, 0, dp(6))
    }

    private fun button(text: String, onClick: () -> Unit) = Button(this).apply {
        this.text = text
        isAllCaps = false
        setOnClickListener { onClick() }
    }

    private fun step(done: Boolean, title: String) = heading((if (done) "✓  " else "○  ") + title).apply {
        if (done) setTextColor(Color.rgb(22, 163, 74))
    }

    /** Rebuild the screen from the current state. Simple and always correct. */
    private fun build() {
        content.removeAllViews()
        content.addView(TextView(this).apply {
            text = "Prosperity Voice"
            textSize = 26f
            setTypeface(typeface, Typeface.BOLD)
        })
        content.addView(body("Talk instead of type, in any app. Tap the mic on the Prosperity Voice keyboard, talk as long as you like, and tap again. Your words are cleaned up and typed for you."))

        // 1. Microphone
        content.addView(step(micAllowed(), "1. Allow the microphone"))
        if (!micAllowed()) content.addView(button("Allow microphone") {
            requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 1)
        })

        // 2. Speech model
        val modelReady = Whisper.modelReady(this)
        content.addView(step(modelReady, "2. Download the speech model"))
        if (!modelReady) {
            content.addView(body("About 150 MB, one time. Your voice is turned into text on this phone and never leaves it. Wi-Fi recommended."))
            if (downloading) {
                content.addView(ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal).apply {
                    max = 100; progress = (downloadProgress * 100).toInt()
                })
                content.addView(body("Downloading… ${(downloadProgress * 100).toInt()}%"))
            } else content.addView(button("Download") { download() })
        }

        // 3. Keyboard
        val enabled = keyboardEnabled()
        content.addView(step(enabled && keyboardSelected(), "3. Turn on the keyboard"))
        if (!enabled) {
            content.addView(body("In the list that opens, turn on Prosperity Voice. Android shows a standard warning for every keyboard; Prosperity Voice only types what you dictate."))
            content.addView(button("Open keyboard settings") { startActivity(Intent(SystemSettings.ACTION_INPUT_METHOD_SETTINGS)) })
        } else if (!keyboardSelected()) {
            content.addView(body("Tap in the box below, then switch to the Prosperity Voice keyboard. You can also switch any time with the keyboard button at the bottom of the screen."))
            content.addView(button("Choose keyboard") { getSystemService(InputMethodManager::class.java).showInputMethodPicker() })
        }

        // 4. Cleanup AI
        settingsBox.removeAllViews()
        run {
        val content = settingsBox
        content.addView(heading("4. Cleanup AI"))
        content.addView(body("Removes \"um\"s, fixes punctuation and self-corrections, and keeps your words."))
        val group = RadioGroup(this)
        for (e in Engine.entries) {
            val rb = RadioButton(this).apply {
                id = View.generateViewId()
                text = e.label + when {
                    e == Engine.NANO && nanoStatus == "unavailable" -> " — not on this phone"
                    e == Engine.NANO && nanoStatus == "downloadable" -> " — Google downloads it the first time"
                    e == Engine.NANO && nanoStatus == "downloading" -> " — downloading"
                    else -> ""
                }
                isEnabled = !(e == Engine.NANO && nanoStatus == "unavailable")
                isChecked = settings.engine == e
                textSize = 15f
            }
            rb.setOnCheckedChangeListener { _, checked -> if (checked && settings.engine != e) { settings.engine = e; build() } }
            group.addView(rb)
        }
        content.addView(group)
        if (settings.engine == Engine.NANO && nanoStatus == "downloadable") {
            content.addView(button("Download Gemini Nano") {
                scope.launch { runCatching { Cleaner.nanoDownload() }; nanoStatus = Cleaner.nanoStatus(); build() }
                nanoStatus = "downloading"; build()
            })
        }
        if (settings.engine == Engine.GEMINI) {
            content.addView(body("Get a free key at aistudio.google.com (sign in with Google, then Get API key), and paste it here. Your text goes to Google to be cleaned up."))
            content.addView(button("Get a free key") { startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://aistudio.google.com/apikey"))) })
            content.addView(EditText(this).apply {
                hint = "Paste your Gemini key"
                setText(settings.geminiKey)
                inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD
                addTextChangedListener(watcher { settings.geminiKey = it })
            })
        }
        if (settings.engine != Engine.OFF) {
            val result = body("")
            content.addView(button("Test cleanup AI") {
                result.text = "Testing…"
                scope.launch {
                    val sample = "so um i was thinking we could meet on tuesday no wait thursday to go over the the numbers"
                    val started = System.currentTimeMillis()
                    val out = withContext(Dispatchers.Default) { Cleaner.cleanDictation(this@MainActivity, sample, settings) }
                    val secs = (System.currentTimeMillis() - started) / 100 / 10.0
                    result.text = if (out.engine == "raw") "Didn't work: ${out.note}" else "Works (${secs}s): ${out.text}"
                }
            })
            content.addView(result)
        }

        // 5. Words
        content.addView(heading("Words to spell right"))
        content.addView(body("Names and words it should spell your way, separated by commas or lines. If it keeps mishearing one, add a fix line like:  Clawed => Claude"))
        content.addView(EditText(this).apply {
            setText(settings.customWords)
            minLines = 3
            inputType = InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_FLAG_MULTI_LINE
            addTextChangedListener(watcher { settings.customWords = it })
        })

        }

        // History
        historyBox.removeAllViews()
        val content = historyBox
        content.addView(heading("History"))
        content.addView(CheckBox(this).apply {
            text = "Keep a history on this phone"
            isChecked = settings.keepHistory
            setOnCheckedChangeListener { _, c -> settings.keepHistory = c }
        })
        val entries = History(this).all().take(20)
        if (entries.isEmpty()) content.addView(body("Nothing yet."))
        val fmt = DateFormat.getDateTimeInstance(DateFormat.SHORT, DateFormat.SHORT)
        for (e in entries) {
            content.addView(TextView(this).apply {
                text = "${fmt.format(Date(e.time))}\n${e.text}"
                textSize = 14f
                setPadding(0, dp(8), 0, dp(8))
                setOnClickListener {
                    getSystemService(android.content.ClipboardManager::class.java)
                        .setPrimaryClip(android.content.ClipData.newPlainText("Prosperity Voice", e.text))
                    Toast.makeText(this@MainActivity, "Copied", Toast.LENGTH_SHORT).show()
                }
            })
        }
        if (entries.isNotEmpty()) content.addView(button("Clear history") { History(this).clear(); build() })

        content.addView(body("\nVersion ${packageManager.getPackageInfo(packageName, 0).versionName}. Free for personal, non-commercial use.").apply { textSize = 12f })
        content.addView(button("Check for updates") {
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/itsmikehobbs/prosperity-voice/releases/latest")))
        })
    }

    private fun watcher(onChange: (String) -> Unit) = object : TextWatcher {
        override fun beforeTextChanged(s: CharSequence?, start: Int, count: Int, after: Int) {}
        override fun onTextChanged(s: CharSequence?, start: Int, before: Int, count: Int) {}
        override fun afterTextChanged(s: Editable?) { onChange(s?.toString() ?: "") }
    }

    private fun download() {
        downloading = true
        downloadProgress = 0f
        build()
        scope.launch {
            var lastShown = -1
            val error = withContext(Dispatchers.IO) {
                runCatching {
                    Whisper.download(this@MainActivity) { p ->
                        val pct = (p * 100).toInt()
                        if (pct != lastShown) {
                            lastShown = pct
                            runOnUiThread { downloadProgress = p; build() }
                        }
                    }
                }.exceptionOrNull()
            }
            downloading = false
            if (error != null) Toast.makeText(this@MainActivity, "Download failed: ${error.message}", Toast.LENGTH_LONG).show()
            else Log.write(this@MainActivity, "speech model downloaded")
            build()
        }
    }
}
