package com.example.meeting_recorder.public_lab_v46.groq_stt_lab

/** Real elapsedRealtime only. No accelerated mode, samples-as-time or wall clock. */
internal class LabDLongClock(private val anchorMs:Long) {
  companion object {
    const val HOUR_MS=60L*60L*1000L
    const val REMINDER_MS=120L*60L*1000L
    const val CAP_MS=150L*60L*1000L
  }
  enum class Phase { ARMED, PENDING, CONTINUED, STOP_REQUESTED, SEALED, STOPPED_EARLY }
  enum class Delivery { NONE, HOUR_CHECKPOINT, FOREGROUND_REMINDER, BACKGROUND_NOTIFICATION }
  init { check(anchorMs>=0){"LAB_D_LONG_CLOCK_HOLD"} }
  private var last=anchorMs
  private var hourSeen=false
  private var phase=Phase.ARMED
  @Synchronized fun elapsedMs()=last-anchorMs
  @Synchronized fun phase()=phase
  @Synchronized fun checkpoint()=hourSeen
  @Synchronized fun pending()=phase==Phase.PENDING
  @Synchronized fun tick(nowMs:Long,foreground:Boolean,recording:Boolean):Delivery {
    check(nowMs>=last){"LAB_D_LONG_CLOCK_REGRESSION_HOLD"}
    last=nowMs
    if(!recording || phase!=Phase.ARMED)return Delivery.NONE
    if(!hourSeen && elapsedMs()>=HOUR_MS) {
      hourSeen=true
      return Delivery.HOUR_CHECKPOINT
    }
    if(elapsedMs()>=REMINDER_MS) {
      phase=Phase.PENDING
      return if(foreground) Delivery.FOREGROUND_REMINDER else Delivery.BACKGROUND_NOTIFICATION
    }
    return Delivery.NONE
  }
  @Synchronized fun continueRecording() {
    check(phase==Phase.PENDING){"LAB_D_LONG_CHOICE_HOLD"}
    phase=Phase.CONTINUED
  }
  @Synchronized fun endRecording() {
    check(phase==Phase.PENDING || phase==Phase.CONTINUED){"LAB_D_LONG_CHOICE_HOLD"}
    phase=Phase.STOP_REQUESTED
  }
  @Synchronized fun sealed(verified:Boolean) {
    check(phase==Phase.STOP_REQUESTED && verified){"LAB_D_LONG_SEAL_HOLD"}
    phase=Phase.SEALED
  }
  @Synchronized fun stopWithoutChoice() {
    if(phase!=Phase.SEALED) phase=Phase.STOPPED_EARLY
  }
}
