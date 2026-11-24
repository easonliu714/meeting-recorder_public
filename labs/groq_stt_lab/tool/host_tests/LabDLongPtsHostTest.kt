package com.example.meeting_recorder.public_lab_v40.groq_stt_lab
import java.io.File
import java.nio.file.Files
object LabDLongPtsHostTest {
  @JvmStatic fun main(args:Array<String>) {
    val ns=100000000000L
    val s1=LabDLongPts.Sample(16000L,14000L,ns,ns+100000)
    val s2=LabDLongPts.Sample(57600000L,57598000L,ns+3600000000000L,ns+3600001000000L)
    val s3=LabDLongPts.Sample(115200000L,115198000L,ns+7200000000000L,ns+7200001000000L)
    fun rejects(f:()->Unit) {check(runCatching{f()}.isFailure)}
    check(LabDLongPts.inspect(emptyList())=="NOT_VERIFIED")
    check(LabDLongPts.inspect(listOf(s1))=="NOT_VERIFIED")
    check(LabDLongPts.inspect(listOf(s1,s2,s3))=="HARDWARE_PTS_OBSERVED_NOT_GAP_FREE")
    check(LabDLongPts.inspect(listOf(s1,s2.copy(hardwareFrames=null,hardwareNs=null)))=="NOT_VERIFIED")
    check(LabDLongPts.inspect(listOf(s1,s2.copy(hardwareFrames=13000L)))=="LAB_D_LONG_PTS_RESET_OR_STALL_HOLD")
    check(LabDLongPts.inspect(listOf(s1,s2.copy(hardwareFrames=47000L)))=="LAB_D_LONG_PTS_UNALIGNED_HOLD")
    val intervals=LabDLongPts.crosswalk(listOf(s1,s2,s3))
    check(intervals.size==2)
    check(intervals[0]["crosses60"]==true && intervals[0]["crosses120"]==false)
    check(intervals[1]["crosses60"]==false && intervals[1]["crosses120"]==true)
    check(intervals[0]["hardwareMinusPcm"]==0L)
    check(intervals[0]["hardwareClockMinusFramesNs"]==1000000000L)
    check(intervals[0]["state"]=="WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE")
    check(intervals[1]["hardwareClockMinusFramesNs"]==0L)
    check(LabDLongPts.crosswalk(emptyList()).isEmpty())
    check(LabDLongPts.crosswalk(listOf(s1)).isEmpty())
    fun pair(b:LabDLongPts.Sample)=LabDLongPts.crosswalk(listOf(s1,b)).single()
    val gap=pair(s2.copy(hardwareFrames=s2.hardwareFrames!!+32001L))
    check(gap["hardwareMinusPcm"]==32001L && gap["state"]=="POSSIBLE_GAP")
    val overlap=pair(s2.copy(hardwareFrames=s2.hardwareFrames!!-32001L))
    check(overlap["hardwareMinusPcm"] == -32001L && overlap["state"]=="POSSIBLE_OVERLAP")
    check(pair(s2.copy(hardwareFrames=s2.hardwareFrames!!+32000L))["state"]==
        "WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE")
    val unavailable=pair(s2.copy(hardwareFrames=null,hardwareNs=null))
    check(unavailable["state"]=="UNKNOWN" && unavailable["hardwareMinusPcm"]==null &&
        unavailable["crosses60"]==true)
    val reset=pair(s2.copy(hardwareFrames=13000L))
    check(reset["state"]=="RESET_OR_STALL" && reset["hardwareClockMinusFramesNs"]==null)
    check(pair(s2.copy(hardwareNs=ns))["state"]=="RESET_OR_STALL")
    val drift=pair(s2.copy(hardwareNs=s2.hardwareNs!!-4000000000L))
    check(drift["state"]=="HARDWARE_CLOCK_UNALIGNED")
    // The elapsed-realtime observation interval is kept separate, even
    // if suspend changes its relation to the hardware monotonic timebase.
    val suspended=pair(s2.copy(observedMonoNs=s2.observedMonoNs+90000000000L))
    check(suspended["hardwareClockMinusFramesNs"]==1000000000L)
    check(suspended["observedElapsedNs"]==s2.observedMonoNs+90000000000L-s1.observedMonoNs)
    check(suspended["state"]=="WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE")
    rejects{LabDLongPts.crosswalk(listOf(s1,s1))}
    rejects{LabDLongPts.inspect(listOf(s1,s1))}
    rejects{LabDLongPts.inspect(listOf(s1.copy(hardwareNs=null)))}
    rejects{LabDLongPts.inspect(listOf(s1.copy(capturedFrames=144000001)))}
    val d=Files.createTempDirectory("lab-d-long-pts").toFile()
    try {
      LabDLongPts.publish(d,1,s1)
      LabDLongPts.publish(d,2,s2)
      LabDLongPts.publish(d,3,s3)
      check(LabDLongPts.read(d)==listOf(s1,s2,s3))
      rejects{LabDLongPts.publish(d,3,s3)}
      File(d,"longpts_000002.receipt").writeText("tampered")
      rejects{LabDLongPts.read(d)}
    }finally{d.listFiles()?.forEach{it.delete()};d.delete()}
    println("LAB_D_LONG_HARDWARE_PTS_HOST_PASS")
  }
}
