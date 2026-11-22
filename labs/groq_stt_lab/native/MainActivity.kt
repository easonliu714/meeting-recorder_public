package com.example.meeting_recorder.public_lab_v32.groq_stt_lab

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/** Public isolated Lab v32: no network calls, source deletion or API keys. */
class MainActivity : FlutterActivity() {
    private val audioWorker = Executors.newSingleThreadExecutor()
    private val probeRunning = AtomicBoolean(false)
    private val probeStop = AtomicBoolean(false)
    private var probeForeground = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "groq_stt_lab/offline_audio").setMethodCallHandler { call, result ->
            if (call.method == "stopLabMicInterruptProbe") {
                probeStop.set(true)
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "startLabMicInterruptProbe") {
                if (!probeForeground) {
                    result.error("LAB_MIC_INTERRUPT_FOREGROUND_HOLD", "Foreground required", null)
                    return@setMethodCallHandler
                }
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                    != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 40130)
                    result.error("LAB_MIC_PERMISSION_REQUIRED_HOLD",
                        "Explicit user permission required", null)
                    return@setMethodCallHandler
                }
                if (!probeRunning.compareAndSet(false, true)) {
                    result.error("LAB_MIC_INTERRUPT_BUSY_HOLD", "Probe already running", null)
                    return@setMethodCallHandler
                }
                probeStop.set(false)
                audioWorker.execute {
                    try {
                        val proof = LabMicPartRecorder.captureInterruptProbe(applicationContext) {
                            probeStop.get()
                        }
                        runOnUiThread { result.success(proof) }
                    } catch (error: Exception) {
                        val code = error.message
                            ?.takeIf { Regex("^[A-Z][A-Z0-9_]{1,63}$").matches(it) }
                            ?: "LAB_MIC_INTERRUPT_CAPTURE_HOLD"
                        runOnUiThread { result.error(code, "Local probe held", null) }
                    } finally {
                        probeRunning.set(false)
                    }
                }
                return@setMethodCallHandler
            }
            if (call.method == "captureLabMicParts") {
                // Never start microphone capture automatically after permission.
                // An explicit second user tap is required on permission grant.
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)
                    != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), 40130)
                    result.error("LAB_MIC_PERMISSION_REQUIRED_HOLD",
                        "Explicit user permission required", null)
                    return@setMethodCallHandler
                }
                audioWorker.execute {
                    try {
                        val proof = LabMicPartRecorder.capture(applicationContext)
                        runOnUiThread { result.success(proof) }
                    } catch (error: Exception) {
                        val code = error.message
                            ?.takeIf { Regex("^[A-Z][A-Z0-9_]{1,63}$").matches(it) }
                            ?: "LAB_MIC_CAPTURE_FAILURE_HOLD"
                        runOnUiThread {
                            result.error(code, "Local microphone capture held", null)
                        }
                    }
                }
                return@setMethodCallHandler
            }
            if (call.method != "inspectAudio" && call.method != "decodeAudioWindow" &&
                call.method != "inspectPartPts") {
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
                    val output = when (call.method) {
                        "inspectAudio" -> GroqLabAudioDecoder.inspectSource(sourcePath)
                        "inspectPartPts" -> GroqLabAudioDecoder.inspectSourcePts(sourcePath)
                        else -> GroqLabAudioDecoder.decodeWindow(
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

    override fun onResume() {
        super.onResume()
        probeForeground = true
    }

    override fun onPause() {
        probeForeground = false
        if (probeRunning.get()) probeStop.set(true)
        super.onPause()
    }

    override fun onDestroy() {
        probeStop.set(true)
        audioWorker.shutdownNow()
        super.onDestroy()
    }
}
