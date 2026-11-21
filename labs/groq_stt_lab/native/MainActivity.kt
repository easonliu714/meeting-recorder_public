package com.example.meeting_recorder.public_lab_v28.groq_stt_lab

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/** Private offline Lab v0.2: no network calls, source deletion or API keys. */
class MainActivity : FlutterActivity() {
    private val audioWorker = Executors.newSingleThreadExecutor()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "groq_stt_lab/offline_audio").setMethodCallHandler { call, result ->
            if (call.method != "inspectAudio" && call.method != "decodeAudioWindow") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            val sourcePath = call.argument<String>("sourcePath")
            if (sourcePath.isNullOrBlank()) {
                result.error("LAB_AUDIO_MISSING_SOURCE", "Missing source path", null)
                return@setMethodCallHandler
            }
            val startMs = call.argument<Number>("startMs")?.toLong()
            val endMs = call.argument<Number>("endMs")?.toLong()
            if (call.method == "decodeAudioWindow" &&
                (startMs == null || endMs == null)) {
                result.error("LAB_AUDIO_BAD_WINDOW", "Missing time window", null)
                return@setMethodCallHandler
            }
            audioWorker.execute {
                try {
                    val output = if (call.method == "inspectAudio") {
                        GroqLabAudioDecoder.inspectSource(sourcePath)
                    } else {
                        GroqLabAudioDecoder.decodeWindow(
                            applicationContext, sourcePath,
                            requireNotNull(startMs), requireNotNull(endMs))
                    }
                    runOnUiThread { result.success(output) }
                } catch (error: Exception) {
                    // Only forward symbolic diagnostic codes. Never send native
                    // paths, filenames, decoded bytes, or raw exception text.
                    val code = error.message
                        ?.takeIf { Regex("^[A-Z][A-Z0-9_]{1,63}$").matches(it) }
                        ?: "LAB_AUDIO_DECODE_HOLD"
                    runOnUiThread {
                        result.error(code,
                            "Offline audio operation failed closed",
                            (error as? LabPcmWindowEvidence)?.safeMetrics
                                ?: (error as? LabLeadingPtsEvidence)?.safeMetrics)
                    }
                }
            }
        }
    }

    override fun onDestroy() {
        audioWorker.shutdownNow()
        super.onDestroy()
    }
}
