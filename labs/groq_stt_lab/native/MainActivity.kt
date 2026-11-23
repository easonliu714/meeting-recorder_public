package com.example.meeting_recorder.public_lab_v36.groq_stt_lab

import android.Manifest
import android.content.pm.PackageManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Public isolated Lab v36: no network calls, source deletion or API keys. */
class MainActivity : FlutterActivity() {
    private val audioWorker = Executors.newSingleThreadExecutor()
    private val probeRunning = AtomicBoolean(false)
    private val probeStop = AtomicBoolean(false)
    private var probeForeground = false
    private val multiRunning = AtomicBoolean(false)
    private val multiMode = AtomicInteger(0)
    private val multiCaptured = AtomicInteger(0)
    private val multiCommitted = AtomicInteger(0)

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,
            "groq_stt_lab/offline_audio").setMethodCallHandler { call, result ->
            if (call.method == "labBackgroundStatus" || call.method == "labReminderStatus") {
                result.success(LabBackgroundRecorderService.status())
                return@setMethodCallHandler
            }
            if (call.method == "labReminderContinue" || call.method == "labReminderEnd") {
                try {
                    if(call.method=="labReminderContinue") LabBackgroundRecorderService.cContinue()
                    else LabBackgroundRecorderService.cEnd()
                    result.success(LabBackgroundRecorderService.status())
                } catch(e:Exception) {
                    val code=e.message?.takeIf { Regex("^LAB_C_[A-Z0-9_]{2,55}_HOLD$").matches(it) }
                        ?: "LAB_C_CHOICE_HOLD"
                    result.error(code,"Simulated reminder choice rejected",null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "labBackgroundStop") {
                LabBackgroundRecorderService.requestStop()
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "labBackgroundStart" || call.method == "labReminderStart") {
                if (!probeForeground || probeRunning.get() || multiRunning.get() ||
                    LabBackgroundRecorderService.isActive()) {
                    result.error("LAB_B_BUSY_OR_BACKGROUND_HOLD","Explicit visible start required",null)
                    return@setMethodCallHandler
                }
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO)!=PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO),40130)
                    result.error("LAB_MIC_PERMISSION_REQUIRED_HOLD","Explicit permission required",null)
                    return@setMethodCallHandler
                }
                if (android.os.Build.VERSION.SDK_INT>=33 &&
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),40131)
                    result.error("LAB_B_NOTIFICATION_PERMISSION_HOLD","Visible notification required",null)
                    return@setMethodCallHandler
                }
                try {
                    LabBackgroundRecorderService.begin(applicationContext,
                        acceleratedC=call.method=="labReminderStart")
                    result.success(LabBackgroundRecorderService.status())
                } catch (e:Exception) {
                    val code=e.message?.takeIf{Regex("^[A-Z][A-Z0-9_]{1,63}$").matches(it)}
                        ?:"LAB_B_SERVICE_START_HOLD"
                    result.error(code,"Background service held",null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "labMultiProgress") {
                result.success(mapOf("frames" to multiCaptured.get(), "committed" to multiCommitted.get()))
                return@setMethodCallHandler
            }
            if (call.method == "labMultiInterrupt" || call.method == "labMultiFinish") {
                if (multiRunning.get()) multiMode.compareAndSet(0, if (call.method == "labMultiInterrupt") 1 else 2)
                result.success(null)
                return@setMethodCallHandler
            }
            if (call.method == "labMultiStart" || call.method == "labMultiRecover") {
                val capture = call.method == "labMultiStart"
                if (!probeForeground || probeRunning.get() || multiRunning.get() || LabBackgroundRecorderService.isActive()) {
                    result.error("LAB_MULTI_BUSY_OR_BACKGROUND_HOLD","Explicit foreground action required",null)
                    return@setMethodCallHandler
                }
                if (capture && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO),40130)
                    result.error("LAB_MIC_PERMISSION_REQUIRED_HOLD","Explicit user permission required",null)
                    return@setMethodCallHandler
                }
                multiRunning.set(true)
                multiMode.set(0);multiCaptured.set(0);multiCommitted.set(0)
                audioWorker.execute {
                    try {
                        val out=if(capture) LabMultiPartCapture.capture(applicationContext,multiMode,multiCaptured,multiCommitted)
                            else LabMultiPartCapture.recover(applicationContext)
                        runOnUiThread { result.success(out) }
                    } catch (error:Exception) {
                        val code=error.message?.takeIf { Regex("^[A-Z][A-Z0-9_]{1,63}$").matches(it) }
                            ?: "LAB_MULTI_CAPTURE_OR_STORAGE_HOLD"
                        runOnUiThread { result.error(code,"Local multi-Part operation held",null) }
                    } finally { multiRunning.set(false) }
                }
                return@setMethodCallHandler
            }
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
        LabBackgroundRecorderService.setUiForeground(true)
    }

    override fun onPause() {
        probeForeground = false
        LabBackgroundRecorderService.setUiForeground(false)
        if (probeRunning.get()) probeStop.set(true)
        if (multiRunning.get()) multiMode.compareAndSet(0,1)
        super.onPause()
    }

    override fun onDestroy() {
        probeStop.set(true)
        multiMode.compareAndSet(0,1)
        audioWorker.shutdownNow()
        super.onDestroy()
    }
}
