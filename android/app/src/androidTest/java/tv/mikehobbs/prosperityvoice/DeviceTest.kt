package tv.mikehobbs.prosperityvoice

import android.content.Context
import android.content.Intent
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.Until
import org.junit.Assert.assertTrue
import org.junit.BeforeClass
import org.junit.FixMethodOrder
import org.junit.Test
import org.junit.runner.RunWith
import org.junit.runners.MethodSorters
import java.io.File

/** On-device checks: model download, speech with no time limit, and the keyboard typing into a text box. */
@RunWith(AndroidJUnit4::class)
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class DeviceTest {
    companion object {
        private val app: Context get() = InstrumentationRegistry.getInstrumentation().targetContext

        private fun shell(cmd: String): String {
            val pfd = InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(cmd)
            return android.os.ParcelFileDescriptor.AutoCloseInputStream(pfd).bufferedReader().use { it.readText() }
        }

        /** Copy a test recording into the app's storage. */
        fun asset(name: String): File {
            val f = File(app.filesDir, "test-$name")
            InstrumentationRegistry.getInstrumentation().context.assets.open(name).use { input -> f.outputStream().use { input.copyTo(it) } }
            return f
        }

        @BeforeClass @JvmStatic fun setUp() {
            if (!Whisper.modelReady(app)) Whisper.download(app) {}
        }

        fun log(msg: String) = android.util.Log.i("PVTest", msg)
    }

    @Test fun a_modelIsReady() {
        assertTrue(Whisper.modelReady(app))
    }

    @Test fun b_transcribesShortDictation() {
        val start = System.currentTimeMillis()
        val text = Recorder.transcribeFile(app, asset("short.wav"), emptyList())
        log("short: ${System.currentTimeMillis() - start} ms: $text")
        val l = text.lowercase()
        assertTrue(text, l.contains("store") && l.contains("party"))
    }

    @Test fun c_transcribesTwoMinutesWithEveryItem() {
        val start = System.currentTimeMillis()
        val text = Recorder.transcribeFile(app, asset("long.wav"), emptyList())
        log("long (1:52): ${System.currentTimeMillis() - start} ms, ${Cleaner.wordCount(text)} words")
        val l = text.lowercase()
        assertTrue(text, l.contains("hardware store") && l.contains("blue scarf") && Cleaner.wordCount(text) > 350)
    }

    @Test fun d_transcribesThreeMinutesNoLimit() {
        // 3 min 9 s, 677 words, every sentence different (Whisper drops exact repeats, so a
        // repeated test sentence isn't a fair test).
        val start = System.currentTimeMillis()
        val text = Recorder.transcribeFile(app, asset("long4.wav"), emptyList())
        log("long4 (3:09): ${System.currentTimeMillis() - start} ms, ${Cleaner.wordCount(text)} words")
        val l = text.lowercase()
        assertTrue(text.takeLast(300), l.contains("blue scarf") && l.contains("drip irrigation") &&
            l.contains("green umbrella") && Cleaner.wordCount(text) > 600)
    }

    private fun openTryItWithKeyboard(): Pair<UiDevice, androidx.test.uiautomator.UiObject2> {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        val ime = "${app.packageName}/.VoiceKeyboard"
        shell("pm grant ${app.packageName} android.permission.RECORD_AUDIO")
        shell("ime enable $ime")
        shell("ime set $ime")
        app.startActivity(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        val field = device.wait(Until.findObject(By.desc("Try it here")), 10000)
            ?: device.findObject(By.scrollable(true))?.let { it.scrollUntil(androidx.test.uiautomator.Direction.DOWN, Until.findObject(By.desc("Try it here"))) }
        checkNotNull(field) { "Try-it box not found" }
        field.click()
        checkNotNull(device.wait(Until.findObject(By.textContains("Tap to talk")), 10000)) { "Prosperity Voice keyboard didn't open" }
        return device to field
    }

    @Test fun e_keyboardTypesDictationIntoTextBox() {
        Settings(app).engine = Engine.OFF
        val (device, field) = openTryItWithKeyboard()
        val wav = asset("short.wav")
        app.sendBroadcast(Intent("tv.mikehobbs.prosperityvoice.DEBUG_DICTATE").setPackage(app.packageName).putExtra("wav", wav.path))
        var typed: String? = null
        val until = System.currentTimeMillis() + 30000
        while (System.currentTimeMillis() < until) {
            typed = runCatching { field.text }.getOrNull()
            if (typed?.contains("party") == true) break
            Thread.sleep(300)
        }
        if (typed?.contains("party") != true) typed = null
        if (typed == null) {
            shell("screencap -p /data/local/tmp/pv-typed-fail.png")
            device.findObjects(By.clazz("android.widget.EditText")).forEach { log("edit text: '${it.text}' desc=${it.contentDescription} focused=${it.isFocused}") }
        }
        assertTrue("dictation wasn't typed into the box", typed != null)
        log("typed: $typed")
        shell("screencap -p /data/local/tmp/pv-keyboard.png")
    }

    @Test fun f_micRecordsAndStops() {
        val (device, _) = openTryItWithKeyboard()
        device.findObject(By.textContains("Tap to talk")).click()
        Thread.sleep(800)
        shell("screencap -p /data/local/tmp/pv-recording.png")
        assertTrue("recording didn't start", device.wait(Until.hasObject(By.textContains("Tap when done")), 5000))
        Thread.sleep(2500)
        device.findObject(By.textContains("Tap when done")).click()
        // The emulator's microphone is silent, so the keyboard should say it heard nothing, and keep the recording.
        val done = device.wait(Until.findObject(By.textContains("Didn't catch any words")), 30000)
        assertTrue("recording didn't finish", done != null)
        assertTrue(Settings.recordingFile(app).length() > 44 + 16000 * 2)
    }

    @Test fun g_setupScreen() {
        val device = UiDevice.getInstance(InstrumentationRegistry.getInstrumentation())
        app.startActivity(Intent(app, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        assertTrue(device.wait(Until.hasObject(By.text("Prosperity Voice")), 10000))
        Thread.sleep(1500)
        shell("screencap -p /data/local/tmp/pv-setup.png")
    }
}
