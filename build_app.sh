#!/bin/bash
set -e
# Generates the LiveArabicSubs (Moonshine) Android project in ./LiveArabicSubs, then fetches the speech model

mkdir -p 'LiveArabicSubs'
cat > 'LiveArabicSubs/build.gradle.kts' <<'END_OF_FILE_7f3a'
plugins {
    id("com.android.application") version "8.5.2" apply false
    id("org.jetbrains.kotlin.android") version "2.0.0" apply false
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs'
cat > 'LiveArabicSubs/fetch_model.py' <<'END_OF_FILE_7f3a'
# Runs on the GitHub build machine: downloads the Moonshine English model into the app's assets.
import os, shutil

path = arch = None
try:
    from moonshine_voice import get_model_for_language, ModelArch
    path, arch = get_model_for_language("en", ModelArch.SMALL_STREAMING)
except Exception as e:
    print("Small streaming model not available, using default:", repr(e))
    from moonshine_voice import get_model_for_language
    path, arch = get_model_for_language("en")

arch = int(getattr(arch, "value", arch))
path = str(path)
print("MODEL PATH:", path, "ARCH:", arch)

dst = os.path.join("app", "src", "main", "assets", "models")
os.makedirs(dst, exist_ok=True)
shutil.copytree(path, dst, dirs_exist_ok=True)
with open(os.path.join("app", "src", "main", "assets", "model_arch.txt"), "w") as f:
    f.write(str(arch))

total = 0
for r, _, fs in os.walk(dst):
    for name in fs:
        size = os.path.getsize(os.path.join(r, name)); total += size
        print(" ", os.path.join(r, name), size)
print("TOTAL MB:", total // (1024 * 1024))
assert total > 1_000_000, "model files missing"
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs'
cat > 'LiveArabicSubs/gradle.properties' <<'END_OF_FILE_7f3a'
android.useAndroidX=true
org.gradle.jvmargs=-Xmx2g
android.suppressUnsupportedCompileSdk=35
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs'
cat > 'LiveArabicSubs/settings.gradle.kts' <<'END_OF_FILE_7f3a'
pluginManagement { repositories { google(); mavenCentral(); gradlePluginPortal() } }
dependencyResolutionManagement { repositories { google(); mavenCentral() } }
rootProject.name = "LiveArabicSubs"
include(":app")
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app'
cat > 'LiveArabicSubs/app/build.gradle.kts' <<'END_OF_FILE_7f3a'
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}
android {
    namespace = "com.livesubs.arabic"
    compileSdk = 35
    defaultConfig {
        applicationId = "com.livesubs.arabic.moonshine"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "2.0"
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
    androidResources { noCompress += listOf("ort", "bin", "onnx") }
}
dependencies {
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.appcompat:appcompat:1.7.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.4")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")
    implementation("com.google.mlkit:translate:17.0.3")
    implementation("ai.moonshine:moonshine-voice:0.0.62")
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main'
cat > 'LiveArabicSubs/app/src/main/AndroidManifest.xml' <<'END_OF_FILE_7f3a'
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">

    <!-- Only what is needed: mic, a mic-type foreground service, and internet
         (one-time Arabic model download). -->
    <uses-permission android:name="android.permission.RECORD_AUDIO" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
    <uses-permission android:name="android.permission.INTERNET" />

    <uses-feature android:name="android.hardware.microphone" android:required="true" />


    <application
        android:allowBackup="false"
        android:label="@string/app_name"
        android:theme="@style/Theme.AppCompat.DayNight.NoActionBar">

        <activity
            android:name=".MainActivity"
            android:exported="true"
            android:launchMode="singleTop"
            android:screenOrientation="fullSensor"
            android:configChanges="orientation|screenSize|screenLayout|smallestScreenSize|keyboardHidden">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>

        <service
            android:name=".ListenService"
            android:exported="false"
            android:foregroundServiceType="microphone" />
    </application>
</manifest>
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic'
cat > 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic/ListenService.kt' <<'END_OF_FILE_7f3a'
package com.livesubs.arabic

import ai.moonshine.voice.TranscriptEvent
import ai.moonshine.voice.Transcriber
import android.Manifest
import android.app.*
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.content.res.Resources
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import com.google.mlkit.nl.translate.TranslateLanguage
import com.google.mlkit.nl.translate.Translation
import com.google.mlkit.nl.translate.Translator
import com.google.mlkit.nl.translate.TranslatorOptions
import kotlin.concurrent.thread
import kotlin.math.sqrt

/**
 * Foreground service (type: microphone). Captures the phone microphone with AudioRecord,
 * boosts quiet audio (far-from-TV), streams it into Moonshine (live English speech-to-text),
 * then translates each line to Arabic on-device. Only runs after the user taps Start.
 */
class ListenService : Service() {

    companion object {
        const val ACTION_START = "com.livesubs.arabic.START"
        const val ACTION_STOP = "com.livesubs.arabic.STOP"
        private const val CHANNEL = "listening"
        private const val NOTIF_ID = 1
        private const val SR = 16000
        private const val MAX_FAILURES = 30
    }

    private val main = Handler(Looper.getMainLooper())
    @Volatile private var running = false
    private var worker: Thread? = null
    private var translator: Translator? = null
    @Volatile private var seq = 0
    @Volatile private var shown = 0

    // movie-style subtitle state (touched only on the main thread)
    private var completedCount = 0
    private val cueQueue = ArrayDeque<String>()
    private var live = ""
    private var shownEn = ""
    private var holdUntil = 0L
    private var lastTranslateAt = 0L
    private val pumpRunnable = Runnable { pump(false) }
    private val clearRunnable = Runnable { clearSubtitle() }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) { shutdown(); return START_NOT_STICKY }
        if (running) return START_NOT_STICKY            // already listening: never restart

        try { goForeground() } catch (e: Exception) { fail("Could not start microphone service."); return START_NOT_STICKY }

        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail("Microphone permission is off. Enable it in Settings."); return START_NOT_STICKY
        }
        running = true
        SessionBus.update { UiState(Phase.PREPARING, "", getString(R.string.preparing)) }

        val opts = TranslatorOptions.Builder()
            .setSourceLanguage(TranslateLanguage.ENGLISH)
            .setTargetLanguage(TranslateLanguage.ARABIC).build()
        translator = Translation.getClient(opts).also { t ->
            t.downloadModelIfNeeded()
                .addOnSuccessListener {
                    if (running) {
                        worker = thread(name = "moonshine") { runEngine() }
                    }
                }
                .addOnFailureListener { fail("Arabic translation needs internet the first time.") }
        }
        return START_NOT_STICKY
    }

    // ---------- speech engine (background thread) ----------

    private val visitor = object : TranscriptEvent.Visitor {
        override fun onLineStarted(e: TranscriptEvent.LineStarted) { val t = e.line.text; main.post { handleText(t, false, true) } }
        override fun onLineTextChanged(e: TranscriptEvent.LineTextChanged) { val t = e.line.text; main.post { handleText(t, false, false) } }
        override fun onLineCompleted(e: TranscriptEvent.LineCompleted) { val t = e.line.text; main.post { handleText(t, true, false) } }
        override fun onLineUpdated(e: TranscriptEvent.LineUpdated) {}
        override fun onError(e: TranscriptEvent.Error) {}
    }

    private fun runEngine() {
        try {
            val t = ModelHolder.get(applicationContext)
            t.removeAllListeners()
            t.addListener { event -> event.accept(visitor) }
            t.start()
            var failures = 0
            while (running) {
                val chunks = capture(t)
                if (!running) break
                failures = if (chunks > 20) 1 else failures + 1
                if (failures > MAX_FAILURES) { main.post { fail("Microphone unavailable. Tap Start to try again.") }; break }
                SessionBus.update { it.copy(phase = Phase.RECONNECTING, message = getString(R.string.reconnecting)) }
                try { Thread.sleep((failures * 1000L).coerceAtMost(4000L)) } catch (_: InterruptedException) { break }
            }
            try { t.stop() } catch (_: Throwable) {}
        } catch (e: Throwable) {
            main.post { fail("Speech engine error: ${e.message}") }
        }
    }

    /** Records until stopped or interrupted. Returns how many 100 ms chunks were delivered. */
    private fun capture(t: Transcriber): Int {
        val minBuf = AudioRecord.getMinBufferSize(SR, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        if (minBuf <= 0) return 0
        val chunk = SR / 10
        val rec = try {
            AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SR, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, maxOf(minBuf, chunk * 2 * 4))
        } catch (e: SecurityException) { return 0 }
        if (rec.state != AudioRecord.STATE_INITIALIZED) { rec.release(); return 0 }

        val shorts = ShortArray(chunk)
        val floats = FloatArray(chunk)
        var gain = 1f
        var delivered = 0
        var silent = 0
        try {
            rec.startRecording()
            if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) return 0
            SessionBus.update { it.copy(phase = Phase.LISTENING, message = getString(R.string.listening)) }
            while (running) {
                val n = rec.read(shorts, 0, chunk)
                if (n <= 0) return delivered
                var sum = 0.0
                var peak = 0
                for (i in 0 until n) {
                    val s = shorts[i].toInt()
                    if (kotlin.math.abs(s) > peak) peak = kotlin.math.abs(s)
                    val v = s / 32768f
                    floats[i] = v
                    sum += v * v
                }
                // exact digital silence for 10 s = another app took the microphone: reconnect
                silent = if (peak == 0) silent + 1 else 0
                if (silent > 100) return delivered
                // gentle automatic gain: lifts quiet TV audio up to 8x, never touches loud audio
                val rms = sqrt(sum / n).toFloat()
                val target = if (rms > 0.002f) (0.08f / rms).coerceIn(1f, 8f) else gain
                gain += (target - gain) * 0.05f
                for (i in 0 until n) floats[i] = (floats[i] * gain).coerceIn(-1f, 1f)
                t.addAudio(if (n == chunk) floats else floats.copyOf(n), SR)
                delivered++
            }
            return delivered
        } finally {
            try { rec.stop() } catch (_: Exception) {}
            rec.release()
        }
    }

    // ---------- movie-style subtitles ----------

    private fun fontSp(): Int = getSharedPreferences("prefs", MODE_PRIVATE).getInt("fontSp", 28)

    /** Roughly how many Arabic characters fit in two lines at the chosen font size. */
    private fun capacityChars(): Int {
        val dm = Resources.getSystem().displayMetrics
        val usableDp = dm.widthPixels / dm.density - 96f
        return (2f * usableDp / (fontSp() * 0.55f) * 0.85f).toInt().coerceIn(20, 140)
    }

    private fun maxWords(): Int = (capacityChars() / 7).coerceIn(3, 16)

    /** Splits spoken English into short cues, preferring sentence and comma boundaries. */
    private fun chunk(text: String, maxW: Int): List<String> {
        val words = text.trim().split(Regex("\\s+"))
        val out = ArrayList<String>()
        val cur = ArrayList<String>()
        val commaMin = (maxW * 0.7).toInt().coerceAtLeast(3)
        for (w in words) {
            cur.add(w)
            val endSentence = w.endsWith(".") || w.endsWith("?") || w.endsWith("!")
            val endComma = w.endsWith(",") || w.endsWith(";") || w.endsWith(":")
            if (cur.size >= maxW || (endSentence && cur.size >= 3) || (endComma && cur.size >= commaMin)) {
                out.add(cur.joinToString(" "))
                cur.clear()
            }
        }
        if (cur.isNotEmpty()) out.add(cur.joinToString(" "))
        return out
    }

    private fun handleText(text: String?, final: Boolean, started: Boolean) {
        if (!running) return
        if (started) completedCount = 0                     // a new sentence/utterance begins
        if (text.isNullOrBlank()) return
        val chunks = chunk(text, maxWords())
        val stable = chunks.size - 1                        // all but the last cue are complete
        while (completedCount < stable) {
            cueQueue.addLast(chunks[completedCount])
            completedCount++
        }
        live = if (completedCount > stable) "" else chunks.last()
        pump(final)
    }

    /** Shows one cue at a time: finished cues stay on screen briefly, then the next one replaces them. */
    private fun pump(force: Boolean) {
        if (!running) return
        val now = SystemClock.uptimeMillis()
        if (now < holdUntil) {
            main.removeCallbacks(pumpRunnable)
            main.postDelayed(pumpRunnable, holdUntil - now)
            return
        }
        val fromQueue = cueQueue.isNotEmpty()
        val next = if (fromQueue) cueQueue.removeFirst() else live
        if (next.isBlank()) return
        if (!fromQueue && next == shownEn) { scheduleClear(next); return }
        if (!fromQueue && !force && now - lastTranslateAt < 400) {
            main.removeCallbacks(pumpRunnable)
            main.postDelayed(pumpRunnable, 400 - (now - lastTranslateAt))
            return
        }
        shownEn = next
        lastTranslateAt = now
        if (fromQueue) holdUntil = now + 1100
        val id = ++seq
        translator?.translate(next)?.addOnSuccessListener { ar ->
            if (running && id > shown) {
                shown = id
                SessionBus.update { it.copy(arabic = lastWords(ar, capacityChars())) }
            }
        }
        scheduleClear(next)
        if (cueQueue.isNotEmpty()) {
            main.removeCallbacks(pumpRunnable)
            main.postDelayed(pumpRunnable, 1100)
        }
    }

    /** When speech stops the subtitle disappears, like in a film. */
    private fun scheduleClear(en: String) {
        val words = en.trim().split(Regex("\\s+")).size
        val delay = (1600L + words * 140L).coerceAtMost(4500L)
        main.removeCallbacks(clearRunnable)
        main.postDelayed(clearRunnable, delay)
    }

    private fun clearSubtitle() {
        if (cueQueue.isNotEmpty() || SystemClock.uptimeMillis() < holdUntil) return
        shownEn = ""
        live = ""
        SessionBus.update { it.copy(arabic = "") }
    }

    /** Safety net: if a translation is still too long for two lines, keep its newest words. */
    private fun lastWords(s: String, max: Int): String {
        if (s.length <= max) return s
        val cut = s.takeLast(max)
        val sp = cut.indexOf(' ')
        return if (sp > 0) cut.substring(sp + 1) else cut
    }

    // ---------- lifecycle ----------

    private fun fail(msg: String) {
        SessionBus.update { UiState(Phase.ERROR, "", msg) }
        shutdown()
    }

    private fun shutdown() {
        running = false
        main.removeCallbacksAndMessages(null)
        translator?.close(); translator = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /** Swiping the app away from recents must also turn the microphone off. */
    override fun onTaskRemoved(rootIntent: Intent?) { shutdown() }

    override fun onDestroy() {
        running = false
        main.removeCallbacksAndMessages(null)
        translator?.close()
        if (SessionBus.state.value.phase != Phase.ERROR) SessionBus.update { UiState() }
        super.onDestroy()
    }

    private fun goForeground() {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(NotificationChannel(CHANNEL, "Live translation", NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), PendingIntent.FLAG_IMMUTABLE)
        val stop = PendingIntent.getService(this, 1, Intent(this, ListenService::class.java)
            .setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val n = NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setContentTitle("Microphone is on")
            .setContentText("Translating English to Arabic")
            .setContentIntent(open).setOngoing(true)
            .addAction(0, "Stop", stop).build()
        ServiceCompat.startForeground(this, NOTIF_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
    }
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic'
cat > 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic/MainActivity.kt' <<'END_OF_FILE_7f3a'
package com.livesubs.arabic

import android.Manifest
import android.animation.ObjectAnimator
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.view.View
import android.view.WindowManager
import android.widget.Button
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.repeatOnLifecycle
import kotlinx.coroutines.launch

/**
 * Handles rotation itself (configChanges in the manifest), so the activity is never
 * recreated and the listening service is never touched by turning the phone.
 */
class MainActivity : AppCompatActivity() {

    private lateinit var panelScroll: View
    private lateinit var startButton: Button
    private lateinit var settingsButton: Button
    private lateinit var status: TextView
    private lateinit var subtitle: SubtitleView
    private lateinit var chip: View
    private lateinit var chipStop: Button
    private lateinit var dot: View
    private lateinit var sizeDown: Button
    private lateinit var sizeUp: Button
    private lateinit var chipDown: Button
    private lateinit var chipUp: Button
    private var fontSp = 28
    private lateinit var pulse: ObjectAnimator
    private var localMessage = ""
    private val prefs by lazy { getSharedPreferences("prefs", MODE_PRIVATE) }

    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) startListening() else showDenied()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        ViewCompat.setOnApplyWindowInsetsListener(findViewById(R.id.root)) { v, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars() or WindowInsetsCompat.Type.displayCutout())
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom)
            insets
        }
        WindowInsetsControllerCompat(window, window.decorView).apply {
            isAppearanceLightStatusBars = false
            isAppearanceLightNavigationBars = false
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            window.attributes.layoutInDisplayCutoutMode =
                WindowManager.LayoutParams.LAYOUT_IN_DISPLAY_CUTOUT_MODE_SHORT_EDGES
        }
        panelScroll = findViewById(R.id.panelScroll)
        startButton = findViewById(R.id.startButton)
        settingsButton = findViewById(R.id.settingsButton)
        status = findViewById(R.id.status)
        subtitle = findViewById(R.id.subtitle)
        chip = findViewById(R.id.chip)
        chipStop = findViewById(R.id.chipStop)
        dot = findViewById(R.id.dot)
        sizeDown = findViewById(R.id.sizeDown)
        sizeUp = findViewById(R.id.sizeUp)
        chipDown = findViewById(R.id.chipDown)
        chipUp = findViewById(R.id.chipUp)
        fontSp = prefs.getInt("fontSp", 28)
        for (b in listOf(sizeDown, sizeUp, chipDown, chipUp)) {
            b.isAllCaps = false
            b.background = pill(0x33FFFFFF, 40f)
        }
        sizeDown.setOnClickListener { changeSize(-4) }
        sizeUp.setOnClickListener { changeSize(4) }
        chipDown.setOnClickListener { changeSize(-4) }
        chipUp.setOnClickListener { changeSize(4) }

        chip.background = pill(0x99000000.toInt(), 40f)
        dot.background = GradientDrawable().apply { shape = GradientDrawable.OVAL; setColor(Color.RED) }
        pulse = ObjectAnimator.ofFloat(dot, "alpha", 1f, 0.25f).apply {
            duration = 700; repeatMode = ObjectAnimator.REVERSE; repeatCount = ObjectAnimator.INFINITE
        }
        startButton.isAllCaps = false
        chipStop.isAllCaps = false
        chipStop.background = pill(0x55FFFFFF, 40f)

        startButton.setOnClickListener {
            if (SessionBus.state.value.active) stopListening() else onStartTapped()
        }
        chipStop.setOnClickListener { stopListening() }
        settingsButton.setOnClickListener {
            startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)))
        }

        lifecycleScope.launch {
            repeatOnLifecycle(Lifecycle.State.STARTED) { SessionBus.state.collect { render(it) } }
        }
    }

    override fun onResume() {
        super.onResume()
        if (hasMic()) {                                        // user enabled it in Settings
            settingsButton.visibility = View.GONE
            localMessage = ""
            render(SessionBus.state.value)
        }
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        render(SessionBus.state.value)          // only re-layout; the mic session keeps running
    }

    override fun onDestroy() { pulse.cancel(); super.onDestroy() }

    // ---------- permission flow ----------

    private fun hasMic() =
        ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED

    private fun onStartTapped() {
        when {
            hasMic() -> startListening()
            permanentlyDenied() -> showDenied()                 // never ask again: Android won't show the dialog
            else -> { prefs.edit().putBoolean("asked", true).apply(); permission.launch(Manifest.permission.RECORD_AUDIO) }
        }
    }

    private fun permanentlyDenied() =
        prefs.getBoolean("asked", false) && !shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO)

    private fun showDenied() {
        if (permanentlyDenied()) {
            localMessage = getString(R.string.denied_forever)
            settingsButton.visibility = View.VISIBLE
        } else {
            localMessage = getString(R.string.denied_once)
        }
        status.text = localMessage
    }

    private fun startListening() {
        localMessage = ""
        settingsButton.visibility = View.GONE
        ContextCompat.startForegroundService(this, Intent(this, ListenService::class.java).setAction(ListenService.ACTION_START))
    }

    private fun stopListening() { stopService(Intent(this, ListenService::class.java)); SessionBus.update { UiState() } }

    private fun changeSize(delta: Int) {
        fontSp = (fontSp + delta).coerceIn(16, 60)
        prefs.edit().putInt("fontSp", fontSp).apply()
        render(SessionBus.state.value)
    }

    // ---------- UI ----------

    private fun render(s: UiState) {
        val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
        val immersive = landscape && s.active

        // keep awake only while the mic session is active
        if (s.active) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        // full-screen subtitle mode in landscape
        val c = WindowInsetsControllerCompat(window, window.decorView)
        if (immersive) {
            c.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            c.hide(WindowInsetsCompat.Type.systemBars())
        } else c.show(WindowInsetsCompat.Type.systemBars())

        panelScroll.visibility = if (immersive) View.GONE else View.VISIBLE
        chip.visibility = if (s.active) View.VISIBLE else View.GONE
        chipStop.visibility = if (immersive) View.VISIBLE else View.GONE
        if (s.active) { if (!pulse.isStarted) pulse.start() } else pulse.cancel()

        startButton.text = getString(if (s.active) R.string.stop else R.string.start)
        startButton.background = pill(if (s.active) 0xFFD32F2F.toInt() else 0xFF1E88E5.toInt(), 40f)
        status.text = if (s.message.isNotEmpty()) s.message else localMessage

        chipDown.visibility = if (immersive) View.VISIBLE else View.GONE
        chipUp.visibility = if (immersive) View.VISIBLE else View.GONE

        // when idle, show a sample so the size can be chosen before starting
        val preview = !s.active
        subtitle.setSize(fontSp.toFloat())
        subtitle.setText(if (preview) getString(R.string.sample_subtitle) else s.arabic)
        subtitle.visibility = if (preview || s.arabic.isNotBlank()) View.VISIBLE else View.GONE
    }

    private fun pill(color: Int, r: Float) = GradientDrawable().apply {
        setColor(color); cornerRadius = r * resources.displayMetrics.density
    }
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic'
cat > 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic/ModelHolder.kt' <<'END_OF_FILE_7f3a'
package com.livesubs.arabic

import ai.moonshine.voice.Transcriber
import android.content.Context
import java.io.File

/** Loads the bundled Moonshine model once and keeps it for the life of the process. */
object ModelHolder {
    @Volatile private var transcriber: Transcriber? = null

    @Synchronized
    fun get(ctx: Context): Transcriber {
        transcriber?.let { return it }
        val arch = ctx.assets.open("model_arch.txt").bufferedReader().use { it.readText().trim().toInt() }
        val root = File(ctx.filesDir, "models_$arch")
        val marker = File(root, ".done")
        if (!marker.exists()) {
            root.deleteRecursively()
            copyAssets(ctx, "models", root)
            marker.writeText("ok")
        }
        // the model files may sit in a sub-folder: find the folder that holds tokenizer.bin
        val dir = root.walkTopDown().firstOrNull { it.isFile && it.name == "tokenizer.bin" }?.parentFile ?: root
        val t = Transcriber()
        t.loadFromFiles(dir.absolutePath, arch)
        transcriber = t
        return t
    }

    private fun copyAssets(ctx: Context, path: String, dest: File) {
        val children = ctx.assets.list(path)
        if (children.isNullOrEmpty()) {
            dest.parentFile?.mkdirs()
            ctx.assets.open(path).use { i -> dest.outputStream().use { o -> i.copyTo(o) } }
        } else {
            dest.mkdirs()
            for (name in children) copyAssets(ctx, "$path/$name", File(dest, name))
        }
    }
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic'
cat > 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic/SessionBus.kt' <<'END_OF_FILE_7f3a'
package com.livesubs.arabic

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update

enum class Phase { IDLE, PREPARING, LISTENING, RECONNECTING, ERROR }

data class UiState(
    val phase: Phase = Phase.IDLE,
    val arabic: String = "",
    val message: String = ""
) {
    val active get() = phase == Phase.PREPARING || phase == Phase.LISTENING || phase == Phase.RECONNECTING
}

/** Shared state between the listening service and the UI (survives rotation). */
object SessionBus {
    val state = MutableStateFlow(UiState())
    fun update(f: (UiState) -> UiState) = state.update(f)
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic'
cat > 'LiveArabicSubs/app/src/main/java/com/livesubs/arabic/SubtitleView.kt' <<'END_OF_FILE_7f3a'
package com.livesubs.arabic

import android.content.Context
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.util.AttributeSet
import android.view.Gravity
import android.view.View
import android.widget.FrameLayout
import androidx.appcompat.widget.AppCompatTextView

/** Large white Arabic text with a black outline on a subtle transparent black box. RTL, max 2 lines. */
class SubtitleView @JvmOverloads constructor(c: Context, a: AttributeSet? = null) : FrameLayout(c, a) {
    private val outline = AppCompatTextView(c)
    private val fill = AppCompatTextView(c)

    init {
        val d = resources.displayMetrics.density
        setBackgroundColor(0x66000000)
        setPadding((16 * d).toInt(), (6 * d).toInt(), (16 * d).toInt(), (6 * d).toInt())
        for (t in listOf(outline, fill)) {
            t.maxLines = 2
            t.gravity = Gravity.CENTER
            t.textDirection = View.TEXT_DIRECTION_RTL
            t.textAlignment = View.TEXT_ALIGNMENT_CENTER
            t.typeface = Typeface.DEFAULT_BOLD
            addView(t, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT))
        }
        fill.setTextColor(Color.WHITE)
        outline.setTextColor(Color.BLACK)
        outline.paint.style = Paint.Style.STROKE
        outline.paint.strokeJoin = Paint.Join.ROUND
        outline.paint.strokeWidth = 4 * d
        setSize(24f)
    }

    fun setSize(sp: Float) { outline.textSize = sp; fill.textSize = sp }
    fun setText(s: String) { outline.text = s; fill.text = s }
}
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/res/layout'
cat > 'LiveArabicSubs/app/src/main/res/layout/activity_main.xml' <<'END_OF_FILE_7f3a'
<?xml version="1.0" encoding="utf-8"?>
<FrameLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:id="@+id/root"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:background="#000000">

    <ScrollView
        android:id="@+id/panelScroll"
        android:layout_width="match_parent"
        android:layout_height="match_parent"
        android:fillViewport="true">
        <LinearLayout
            android:layout_width="match_parent"
            android:layout_height="wrap_content"
            android:gravity="center"
            android:orientation="vertical"
            android:paddingStart="28dp"
            android:paddingEnd="28dp"
            android:paddingTop="28dp"
            android:paddingBottom="150dp">

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:gravity="center"
                android:text="@string/welcome"
                android:textColor="#FFFFFF"
                android:textSize="26sp"
                android:textStyle="bold" />

            <TextView
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="16dp"
                android:gravity="center"
                android:text="@string/mic_reason"
                android:textColor="#BBBBBB"
                android:textSize="16sp" />

            <LinearLayout
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="24dp"
                android:gravity="center_vertical"
                android:orientation="horizontal">
                <TextView
                    android:layout_width="wrap_content"
                    android:layout_height="wrap_content"
                    android:text="@string/subtitle_size"
                    android:textColor="#DDDDDD"
                    android:textSize="15sp" />
                <Button
                    android:id="@+id/sizeDown"
                    android:layout_width="wrap_content"
                    android:layout_height="48dp"
                    android:layout_marginStart="12dp"
                    android:minWidth="64dp"
                    android:text="@string/smaller"
                    android:textColor="#FFFFFF"
                    android:textSize="18sp" />
                <Button
                    android:id="@+id/sizeUp"
                    android:layout_width="wrap_content"
                    android:layout_height="48dp"
                    android:layout_marginStart="8dp"
                    android:minWidth="64dp"
                    android:text="@string/bigger"
                    android:textColor="#FFFFFF"
                    android:textSize="18sp" />
            </LinearLayout>

            <Button
                android:id="@+id/startButton"
                android:layout_width="match_parent"
                android:layout_height="80dp"
                android:layout_marginTop="32dp"
                android:text="@string/start"
                android:textColor="#FFFFFF"
                android:textSize="20sp"
                android:textStyle="bold" />

            <TextView
                android:id="@+id/status"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="20dp"
                android:gravity="center"
                android:textColor="#DDDDDD"
                android:textSize="15sp" />

            <Button
                android:id="@+id/settingsButton"
                android:layout_width="wrap_content"
                android:layout_height="wrap_content"
                android:layout_marginTop="12dp"
                android:text="@string/open_settings"
                android:visibility="gone" />
        </LinearLayout>
    </ScrollView>

    <com.livesubs.arabic.SubtitleView
        android:id="@+id/subtitle"
        android:layout_width="match_parent"
        android:layout_height="wrap_content"
        android:layout_gravity="bottom|center_horizontal"
        android:layout_marginStart="32dp"
        android:layout_marginEnd="32dp"
        android:layout_marginBottom="24dp"
        android:visibility="gone" />

    <LinearLayout
        android:id="@+id/chip"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content"
        android:layout_gravity="top|start"
        android:layout_margin="12dp"
        android:gravity="center_vertical"
        android:orientation="horizontal"
        android:paddingStart="12dp"
        android:paddingEnd="4dp"
        android:visibility="gone">
        <View
            android:id="@+id/dot"
            android:layout_width="12dp"
            android:layout_height="12dp" />
        <TextView
            android:layout_width="wrap_content"
            android:layout_height="wrap_content"
            android:layout_marginStart="8dp"
            android:text="@string/mic_on"
            android:textColor="#FFFFFF"
            android:textSize="13sp" />
        <Button
            android:id="@+id/chipDown"
            android:layout_width="wrap_content"
            android:layout_height="36dp"
            android:layout_marginStart="6dp"
            android:minWidth="0dp"
            android:text="@string/smaller"
            android:textColor="#FFFFFF"
            android:textSize="13sp"
            android:visibility="gone" />
        <Button
            android:id="@+id/chipUp"
            android:layout_width="wrap_content"
            android:layout_height="36dp"
            android:minWidth="0dp"
            android:text="@string/bigger"
            android:textColor="#FFFFFF"
            android:textSize="13sp"
            android:visibility="gone" />
        <Button
            android:id="@+id/chipStop"
            android:layout_width="wrap_content"
            android:layout_height="36dp"
            android:layout_marginStart="6dp"
            android:minWidth="0dp"
            android:text="@string/stop"
            android:textColor="#FFFFFF"
            android:textSize="13sp"
            android:visibility="gone" />
    </LinearLayout>
</FrameLayout>
END_OF_FILE_7f3a
mkdir -p 'LiveArabicSubs/app/src/main/res/values'
cat > 'LiveArabicSubs/app/src/main/res/values/strings.xml' <<'END_OF_FILE_7f3a'
<resources>
    <string name="app_name">Arabic Subtitles (Moonshine)</string>
    <string name="welcome">Welcome 👋\nWatch anything in English,\nread it in Arabic.</string>
    <string name="mic_reason">Allow microphone access so we can hear the movie and translate it into Arabic.</string>
    <string name="start">Start Live Translation</string>
    <string name="stop">Stop</string>
    <string name="mic_on">Microphone on</string>
    <string name="open_settings">Open Settings</string>
    <string name="denied_once">Microphone access is needed to hear the movie. Tap Start to try again.</string>
    <string name="denied_forever">Microphone access is turned off. To enable it:\nSettings → Apps → Arabic Subtitles (Moonshine) → Permissions → Microphone → Allow.</string>
    <string name="listening">Listening… place your phone near the TV, then rotate it sideways.</string>
    <string name="reconnecting">Microphone interrupted — reconnecting…</string>
    <string name="preparing">Getting ready… (first run: internet needed for Arabic, and loading the speech engine takes a few seconds)</string>
    <string name="subtitle_size">Subtitle size</string>
    <string name="smaller">A−</string>
    <string name="bigger">A+</string>
    <string name="sample_subtitle">هكذا ستظهر الترجمة على الشاشة</string>
</resources>
END_OF_FILE_7f3a
echo "project generated"
if [ -z "$SKIP_MODEL" ]; then
  # diagnostics only (never fails the build): print the Moonshine library API into the log
  ( mkdir -p /tmp/aar && cd /tmp/aar \
    && curl -sSL -o m.aar https://repo1.maven.org/maven2/ai/moonshine/moonshine-voice/0.0.62/moonshine-voice-0.0.62.aar \
    && unzip -oq m.aar classes.jar \
    && javap -cp classes.jar ai.moonshine.voice.Transcriber 'ai.moonshine.voice.TranscriptEvent$Visitor' ai.moonshine.voice.TranscriptEvent ) || true
  cd LiveArabicSubs
  python3 -m venv /tmp/mvenv
  /tmp/mvenv/bin/pip install --quiet moonshine-voice
  /tmp/mvenv/bin/python fetch_model.py
  cd ..
fi
