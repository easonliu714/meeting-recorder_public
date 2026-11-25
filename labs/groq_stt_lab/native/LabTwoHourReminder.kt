package com.example.meeting_recorder.public_lab_v42.groq_stt_lab

/**
 * Gate C reminder core: one immutable elapsed-realtime anchor per meeting.
 * It never reads Part count/duration, microphone samples or wall-clock time.
 * Accelerated clock values are supplied by explicit Lab tests only; production
 * callers must use an actual monotonic elapsed-realtime reading.
 * This state machine never touches audio files, notifications or network APIs.
 */
internal class LabTwoHourReminder(private val startedElapsedMs: Long) {
    companion object { const val THRESHOLD_MS = 120L * 60L * 1000L }
    enum class Phase { ARMED, PENDING, CONTINUED, STOP_REQUESTED, SEALED, STOPPED_EARLY }
    enum class Delivery { NONE, FOREGROUND_CONFIRM, BACKGROUND_NOTIFICATION }

    init { check(startedElapsedMs >= 0L) { "LAB_C_INVALID_ANCHOR_HOLD" } }
    private var lastElapsedMs = startedElapsedMs
    private var phase = Phase.ARMED

    @Synchronized fun state(): Phase = phase
    @Synchronized fun elapsedMs(): Long = lastElapsedMs - startedElapsedMs
    @Synchronized fun pendingOnReturn(): Boolean = phase == Phase.PENDING

    /** Returns a *single* delivery event at the first 120-min crossing. */
    @Synchronized fun onTick(nowElapsedMs: Long, inForeground: Boolean, recording: Boolean): Delivery {
        check(nowElapsedMs >= lastElapsedMs) { "LAB_C_MONOTONIC_CLOCK_HOLD" }
        lastElapsedMs = nowElapsedMs
        if (!recording || phase != Phase.ARMED || elapsedMs() < THRESHOLD_MS) return Delivery.NONE
        phase = Phase.PENDING
        return if (inForeground) Delivery.FOREGROUND_CONFIRM else Delivery.BACKGROUND_NOTIFICATION
    }

    /** Do not alter the time anchor, drop Parts or stop the microphone. */
    @Synchronized fun continueRecording() {
        check(phase == Phase.PENDING) { "LAB_C_CHOICE_STATE_HOLD" }
        phase = Phase.CONTINUED
    }

    /** Caller must stop capture and durably verify valid final receipts. */
    @Synchronized fun requestEnd() {
        check(phase == Phase.PENDING) { "LAB_C_CHOICE_STATE_HOLD" }
        phase = Phase.STOP_REQUESTED
    }

    @Synchronized fun confirmSealed(verified: Boolean) {
        check(phase == Phase.STOP_REQUESTED && verified) { "LAB_C_UNVERIFIED_SEAL_HOLD" }
        phase = Phase.SEALED
    }

    /** A natural/forced stop cannot be silently represented as Continue. */
    @Synchronized fun stopWithoutChoice() {
        if (phase != Phase.SEALED) phase = Phase.STOPPED_EARLY
    }
}
