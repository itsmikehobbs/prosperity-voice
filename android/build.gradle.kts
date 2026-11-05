buildscript {
    // Newer Kotlin than the one bundled with the Android plugin (the coroutines library needs it).
    dependencies { classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:2.4.21") }
}
plugins {
    id("com.android.application") version "9.5.0" apply false
}
