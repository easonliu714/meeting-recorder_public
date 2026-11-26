package com.example.meeting_recorder.public_lab_v43.groq_stt_lab

import java.util.Collections
import java.util.concurrent.CountDownLatch

private fun reject(expected: String, block: () -> Unit) {
    val failure = runCatching(block).exceptionOrNull()
    check(failure?.message == expected) {
        "expected " + expected + ", got " + (failure?.message ?: "SUCCESS")
    }
}

/** Real Kotlin JVM regression, no Android simulator and no mocked audio evidence. */
fun main() {
    val threshold = LabTwoHourReminder.THRESHOLD_MS
    var cases = 0
    fun verify(name: String, block: () -> Unit) {
        block()
        cases++
        println("LAB_C_CLOCK_HOST_PASS " + name)
    }
    verify("119m59s_no_reminder") {
        val a = LabTwoHourReminder(500L)
        check(a.onTick(500L + threshold - 1000L, true, true) == LabTwoHourReminder.Delivery.NONE)
        check(a.state() == LabTwoHourReminder.Phase.ARMED)
    }
    verify("120m_front_dialog_once") {
        val a = LabTwoHourReminder(1000L)
        check(a.onTick(1000L + threshold - 1, true, true) == LabTwoHourReminder.Delivery.NONE)
        check(a.onTick(1000L + threshold, true, true) == LabTwoHourReminder.Delivery.FOREGROUND_CONFIRM)
        check(a.pendingOnReturn())
        check(a.onTick(1000L + threshold, true, true) == LabTwoHourReminder.Delivery.NONE)
    }
    verify("120m_background_notification_pending_on_resume") {
        val a = LabTwoHourReminder(0L)
        check(a.onTick(threshold, false, true) == LabTwoHourReminder.Delivery.BACKGROUND_NOTIFICATION)
        check(a.pendingOnReturn())
        check(a.onTick(threshold + 1L, true, true) == LabTwoHourReminder.Delivery.NONE)
        check(a.pendingOnReturn())
    }
    verify("part_rollover_at_60m_does_not_reset_anchor") {
        val a = LabTwoHourReminder(10L)
        check(a.onTick(10L + 60L * 60_000L, true, true) == LabTwoHourReminder.Delivery.NONE)
        check(a.onTick(10L + threshold, false, true) == LabTwoHourReminder.Delivery.BACKGROUND_NOTIFICATION)
        check(a.elapsedMs() == threshold)
    }
    verify("continue_keeps_microphone_and_suppresses_repeats") {
        val a = LabTwoHourReminder(0)
        a.onTick(threshold, false, true)
        a.continueRecording()
        check(a.state() == LabTwoHourReminder.Phase.CONTINUED)
        check(!a.pendingOnReturn())
        check(a.onTick(threshold + 12_000L, false, true) == LabTwoHourReminder.Delivery.NONE)
        reject("LAB_C_CHOICE_STATE_HOLD") { a.continueRecording() }
        reject("LAB_C_CHOICE_STATE_HOLD") { a.requestEnd() }
    }
    verify("end_requires_verified_seal") {
        val a = LabTwoHourReminder(100)
        a.onTick(100L + threshold, true, true)
        a.requestEnd()
        check(a.state() == LabTwoHourReminder.Phase.STOP_REQUESTED)
        reject("LAB_C_UNVERIFIED_SEAL_HOLD") { a.confirmSealed(false) }
        check(a.state() == LabTwoHourReminder.Phase.STOP_REQUESTED)
        a.confirmSealed(true)
        check(a.state() == LabTwoHourReminder.Phase.SEALED)
        check(a.onTick(100L + threshold + 1L, true, false) == LabTwoHourReminder.Delivery.NONE)
    }
    verify("new_meeting_new_anchor") {
        val old = LabTwoHourReminder(0)
        old.onTick(threshold, true, true)
        old.continueRecording()
        val next = LabTwoHourReminder(threshold + 1000)
        check(next.state() == LabTwoHourReminder.Phase.ARMED)
        check(next.onTick(threshold + 2000, true, true) == LabTwoHourReminder.Delivery.NONE)
    }
    verify("no_prompt_after_recording_stopped") {
        val a = LabTwoHourReminder(0)
        check(a.onTick(threshold, false, false) == LabTwoHourReminder.Delivery.NONE)
        a.stopWithoutChoice()
        check(!a.pendingOnReturn())
        check(a.onTick(threshold + 1, true, true) == LabTwoHourReminder.Delivery.NONE)
    }
    verify("invalid_start_is_rejected") {
        reject("LAB_C_INVALID_ANCHOR_HOLD") { LabTwoHourReminder(-1) }
    }
    verify("monotonic_clock_regression_fails_closed") {
        val a = LabTwoHourReminder(100)
        a.onTick(200, true, true)
        reject("LAB_C_MONOTONIC_CLOCK_HOLD") { a.onTick(199, true, true) }
        check(a.elapsedMs() == 100L)
    }
    verify("request_end_without_pending_is_rejected") {
        val a = LabTwoHourReminder(0)
        reject("LAB_C_CHOICE_STATE_HOLD") { a.requestEnd() }
    }
    verify("simultaneous_ticks_dispatch_once") {
        val a = LabTwoHourReminder(0)
        val gate = CountDownLatch(1)
        val results = Collections.synchronizedList(mutableListOf<LabTwoHourReminder.Delivery>())
        val threads = (1..16).map {
            Thread { gate.await(); results.add(a.onTick(threshold, false, true)) }
        }
        threads.forEach(Thread::start)
        gate.countDown()
        threads.forEach(Thread::join)
        check(results.count { it == LabTwoHourReminder.Delivery.BACKGROUND_NOTIFICATION } == 1)
        check(results.count { it == LabTwoHourReminder.Delivery.NONE } == 15)
    }
    println("LAB_C_CLOCK_HOST_SUITE_PASS cases=" + cases)
}
