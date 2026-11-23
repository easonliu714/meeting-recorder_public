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
