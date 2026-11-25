package com.example.meeting_recorder.public_lab_v42.groq_stt_lab
object LabDLongClockHostTest {
  @JvmStatic fun main(args:Array<String>) {
    val hour=LabDLongClock.HOUR_MS;val reminder=LabDLongClock.REMINDER_MS
    fun rejects(f:()->Unit) {check(runCatching{f()}.isFailure)}
    val m=LabDLongClock(500L)
    check(m.tick(500L+hour-1,true,true)==LabDLongClock.Delivery.NONE)
    check(m.tick(500L+hour,true,true)==LabDLongClock.Delivery.HOUR_CHECKPOINT)
    check(m.checkpoint())
    check(m.tick(500L+reminder-1,false,true)==LabDLongClock.Delivery.NONE)
    check(m.tick(500L+reminder,false,true)==LabDLongClock.Delivery.BACKGROUND_NOTIFICATION)
    check(m.pending())
    check(m.tick(500L+reminder+10000,false,true)==LabDLongClock.Delivery.NONE)
    rejects {m.tick(500L,false,true)}
    m.continueRecording()
    check(!m.pending() && m.phase()==LabDLongClock.Phase.CONTINUED)
    check(m.tick(500L+reminder+1800000,true,true)==LabDLongClock.Delivery.NONE)
    rejects{m.continueRecording()}
    m.endRecording();m.sealed(true)
    check(m.phase()==LabDLongClock.Phase.SEALED)
    val early=LabDLongClock(0)
    early.tick(reminder+1,true,false)
    check(!early.checkpoint() && !early.pending())
    early.stopWithoutChoice()
    rejects{early.endRecording()}
    val foreground=LabDLongClock(0)
    foreground.tick(hour,true,true)
    check(foreground.tick(reminder,true,true)==LabDLongClock.Delivery.FOREGROUND_REMINDER)
    foreground.endRecording(); rejects{foreground.sealed(false)};foreground.sealed(true)
    println("LAB_D_LONG_REAL_MONOTONIC_CLOCK_HOST_PASS")
  }
}
