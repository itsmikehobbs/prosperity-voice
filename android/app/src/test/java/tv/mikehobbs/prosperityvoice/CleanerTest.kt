package tv.mikehobbs.prosperityvoice

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.atomic.AtomicInteger

/** The same checks as the Mac and Windows self-tests, for the shared text rules. */
class CleanerTest {
    @Test fun tidyStripsTagsPreambleAndQuotes() {
        assertEquals("Hello there.", Cleaner.tidy("<transcript>Hello there.</transcript>", "transcript"))
        assertEquals("Hello there.", Cleaner.tidy("Here is the cleaned text:\nHello there.", "transcript"))
        assertEquals("Hello there.", Cleaner.tidy("\"Hello there.\"", "transcript"))
        assertEquals("It's \"fine\".", Cleaner.tidy("It’s “fine”.", "transcript"))
    }

    @Test fun capitalizeFirst() {
        assertEquals("Hello", Cleaner.capitalizeFirst("hello"))
        assertEquals("\"Hello", Cleaner.capitalizeFirst("\"hello"))
    }

    @Test fun acceptsRejectsAnswersAndCutoffs() {
        val input = "so um i was thinking we should go to the store tomorrow and get some stuff"
        assertTrue(Cleaner.accepts(Mode.DICTATION, input, "I was thinking we should go to the store tomorrow and get some stuff."))
        assertFalse(Cleaner.accepts(Mode.DICTATION, input, "Sure."))
        assertFalse(Cleaner.accepts(Mode.DICTATION, input, (input + " ").repeat(3)))
    }

    @Test fun addedNames() {
        assertEquals(listOf("Paris"), Cleaner.addedNames("what is the capital of france", "The capital of France is Paris.", emptyList()))
        assertTrue(Cleaner.addedNames("call jim about the cake", "Then call Jim about the cake.", emptyList()).isEmpty())
        assertTrue(Cleaner.addedNames("ask mike hobs", "Ask Mike Hobbs.", listOf("Mike Hobbs")).isEmpty())
        assertTrue(Cleaner.addedNames("ok so then we go", "Okay. Then we go.", emptyList()).isEmpty())
    }

    @Test fun chunks() {
        val text = (1..30).joinToString(" ") { "Sentence number $it is here." }
        val pieces = Cleaner.chunks(text, 50)
        assertTrue(pieces.size > 1)
        assertTrue(pieces.all { Cleaner.wordCount(it) <= 50 })
        assertEquals(Cleaner.wordCount(text), pieces.sumOf { Cleaner.wordCount(it) })
    }

    @Test fun replacements() {
        val rules = TextRules.parseReplacements("Mike Hobbs, My Cobbs => Mike Hobbs\ncloudflirt=>Cloudflare, red => blue, blue => green")
        assertEquals("ask Mike Hobbs about Cloudflare today", TextRules.applyReplacements("ask my cobbs about Cloudflirt today", rules))
        assertEquals("blue green", TextRules.applyReplacements("red blue", rules))
        assertEquals("bluebird and redo", TextRules.applyReplacements("bluebird and redo", rules))
        assertEquals(listOf("Mike Hobbs"), TextRules.parseWords("Mike Hobbs, My Cobbs => Mike Hobbs"))
    }

    @Test fun parseGeminiSkipsThoughts() {
        val json = """{"candidates":[{"content":{"parts":[{"text":"thinking...","thought":true},{"text":"Hello there."}]}}]}"""
        assertEquals("Hello there.", Cleaner.parseGemini(json))
    }

    @Test fun normalizeAndNoise() {
        assertTrue(Whisper.isNoise("[BLANK_AUDIO]"))
        assertTrue(Whisper.isNoise("(music)"))
        assertFalse(Whisper.isNoise("Hello."))
        assertEquals("a b", Whisper.normalize("  a \t  b "))
    }

    private fun timed(hedge: Double, giveUp: Double, attempt: suspend (Int) -> String): Triple<String?, Double, Int> = runBlocking {
        val calls = AtomicInteger()
        val start = System.nanoTime()
        val out = runCatching { Cleaner.hedged("Test", hedge, giveUp) { attempt(calls.incrementAndGet()) } }.getOrNull()
        Triple(out, (System.nanoTime() - start) / 1e9, calls.get())
    }

    @Test fun hedgeQuickAnswerNoSecondCall() {
        val r = timed(0.3, 2.0) { "fast" }
        assertEquals("fast", r.first); assertEquals(1, r.third)
    }

    @Test fun hedgeSlowCallGetsSecondTryThatWins() {
        val r = timed(0.3, 2.0) { n -> if (n == 1) delay(1500); "call $n" }
        assertEquals("call 2", r.first); assertTrue("took ${r.second}", r.second < 0.9)
    }

    @Test fun hedgeQuickFailureStopsAtOnce() {
        val r = timed(0.3, 2.0) { throw CleanException("bad key") }
        assertNull(r.first); assertTrue(r.second < 0.2); assertEquals(1, r.third)
    }

    @Test fun hedgeGivesUpAtLimit() {
        val r = timed(0.2, 0.6) { delay(5000); "late" }
        assertNull(r.first); assertTrue("took ${r.second}", r.second < 1.0); assertEquals(2, r.third)
    }

    @Test fun wavRoundTrip() {
        val f = java.io.File.createTempFile("pvtest", ".wav")
        val w = Wav.Writer(f)
        val samples = ShortArray(16000) { (kotlin.math.sin(it / 10.0) * 8000).toInt().toShort() }
        w.write(samples, samples.size); w.close()
        val back = Wav.read(f)
        assertEquals(16000, back.size)
        assertEquals(samples[100] / 32768f, back[100], 1e-4f)
        f.delete()
    }
}
