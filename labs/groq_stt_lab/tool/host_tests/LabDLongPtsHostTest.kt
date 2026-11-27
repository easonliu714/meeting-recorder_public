package com.example.meeting_recorder.public_lab_v44.groq_stt_lab
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
    val session=java.util.UUID.randomUUID().toString()
    val lifetime=java.util.UUID.randomUUID().toString()
    fun observed(s:LabDLongPts.Sample,shift:Long=0L):LabDLongPts.Sample {
      val h=requireNotNull(s.hardwareNs)
      val before=h+1000000L
      return s.copy(observedMonoNs=before+shift,
        observation=LabDLongPts.Observation(session,lifetime,before,before+1000000L,
          before+shift,before+shift+1200000L))
    }
    val a=observed(s1);val b=observed(s2)
    check(LabDLongPts.observations(listOf(a)).single()["state"]=="BOUNDED_OBSERVATION_NOT_GAP_FREE")
    check(LabDLongPts.observations(listOf(a)).single()["lagUpperNs"]==2000000L)
    check(LabDLongPts.observations(listOf(s1)).single()["state"]=="LEGACY_TIMEBASE_NOT_VERIFIED")
    check(LabDLongPts.crosswalk(listOf(a,b)).single()["clockObservationState"]=="BOUNDED_INTERVAL_NOT_GAP_FREE")
    check(LabDLongPts.provenance(listOf(a,b))=="LOCAL_SESSION_RECORDER_BOUND_NOT_ATTESTED")
    check(LabDLongPts.inspect(listOf(a,b))=="HARDWARE_PTS_OBSERVED_NOT_GAP_FREE")
    val suspend=observed(s2,90000000000L)
    check(LabDLongPts.crosswalk(listOf(a,suspend)).single()["clockObservationState"]=="POSSIBLE_SUSPEND_HOLD")
    check(LabDLongPts.inspect(listOf(a,suspend))=="LAB_D_LONG_PTS_TIMEBASE_HOLD")
    val future=a.copy(hardwareNs=a.observation!!.afterMonoNs+1)
    check(LabDLongPts.observations(listOf(future)).single()["state"]=="FUTURE_TIMESTAMP_HOLD")
    val wide=a.copy(observation=a.observation!!.copy(afterMonoNs=a.observation!!.beforeMonoNs+50000001L))
    check(LabDLongPts.observations(listOf(wide)).single()["state"]=="WIDE_WINDOW_HOLD")
    val missing=a.copy(hardwareNs=null,hardwareFrames=null)
    check(LabDLongPts.observations(listOf(missing)).single()["state"]=="HARDWARE_UNAVAILABLE_NOT_VERIFIED")
    val stale=a.copy(hardwareNs=a.observation!!.afterMonoNs-2000000001L)
    check(LabDLongPts.observations(listOf(stale)).single()["state"]=="STALE_TIMESTAMP_HOLD")
    rejects{LabDLongPts.inspect(listOf(s1,b))}
    rejects{LabDLongPts.inspect(listOf(a,b.copy(observation=b.observation!!.copy(recorder=java.util.UUID.randomUUID().toString()))))}
    val parent=Files.createTempDirectory("lab-v2-pts").toFile()
    val folder=File(parent,session);check(folder.mkdir())
    try {
      LabDLongPts.publish(folder,1,a);LabDLongPts.publish(folder,2,b)
      check(LabDLongPts.read(folder)==listOf(a,b))
      val original=File(folder,"longpts_000001.receipt").readBytes()
      rejects{LabDLongPts.publish(folder,1,a)}
      check(File(folder,"longpts_000001.receipt").readBytes().contentEquals(original))
      File(folder,"longpts_000002.receipt").writeText("v3\tinvalid\n")
      rejects{LabDLongPts.read(folder)}
    }finally{parent.deleteRecursively()}
    // Synthetic host fixtures only; not Android or continuous acoustic proof.
    val shortA=observed(LabDLongPts.Sample(100L,100L,ns,ns))
    val shortB=observed(LabDLongPts.Sample(80100L,80100L,ns+5000250000L,ns+5000250000L))
    val short=LabDLongPts.coverage(listOf(shortA,shortB),listOf(640000L),true)
    check(short["boundedFrames"]==80000L && short["unknownFrames"]==560000L)
    check(short["continuity"]=="NOT_VERIFIED")
    val shortPart=(short["parts"] as List<*>).single() as Map<*,*>
    val shortSegments=shortPart["segments"] as List<*>
    check(shortSegments.size==3)
    check((shortSegments.first() as Map<*,*>)["state"]=="UNOBSERVED_NOT_VERIFIED")
    check((shortSegments.last() as Map<*,*>)["end"]==640000L)
    check((short["boundaries"] as List<*>).isEmpty())
    val crossA=observed(LabDLongPts.Sample(57590000L,57590000L,ns,ns))
    val crossB=observed(LabDLongPts.Sample(57610000L,57610000L,ns+1250000000L,ns+1250000000L))
    val cross=LabDLongPts.coverage(listOf(crossA,crossB),listOf(57600000L,57620000L),true)
    check(cross["boundedFrames"]==20000L)
    val boundary=(cross["boundaries"] as List<*>).single() as Map<*,*>
    check(boundary["frame"]==57600000L && boundary["state"]=="BOUNDED_PAIR_NOT_GAP_FREE")
    val exact=observed(LabDLongPts.Sample(57600000L,57600000L,ns+625000000L,ns+625000000L))
    val atBoundary=LabDLongPts.coverage(listOf(crossA,exact,crossB),listOf(57600000L,57620000L),true)
    check(((atBoundary["boundaries"] as List<*>).single() as Map<*,*>)["state"]=="BOUNDARY_SAMPLE_ONLY_NOT_VERIFIED")
    val tail=LabDLongPts.coverage(listOf(crossA,crossB),listOf(57600000L),false)
    check(tail["boundedFrames"]==0L && tail["unknownFrames"]==57600000L && tail["outsideCommittedSamples"]==1)
    check((tail["boundaries"] as List<*>).isEmpty())
    rejects{LabDLongPts.coverage(listOf(crossA,crossB),listOf(57600000L),true)}
    val noSamples=LabDLongPts.coverage(emptyList(),listOf(10L,20L),true)
    check(noSamples["unknownFrames"]==20L && noSamples["boundedFrames"]==0L)
    check(((noSamples["boundaries"] as List<*>).single() as Map<*,*>)["state"]=="BOUNDARY_UNOBSERVED_NOT_VERIFIED")
    check(LabDLongPts.coverage(listOf(s1,s2),listOf(57600000L),true)["boundedFrames"]==0L)
    check(LabDLongPts.coverage(listOf(a,suspend),listOf(57600000L),true)["boundedFrames"]==0L)
    check(LabDLongPts.coverage(listOf(shortA),listOf(640000L),true)["unknownFrames"]==640000L)
    check(LabDLongPts.coverage(listOf(shortA,shortB),emptyList(),false)["outsideCommittedSamples"]==2)
    rejects{LabDLongPts.coverage(emptyList(),listOf(10L,10L),true)}
    rejects{LabDLongPts.coverage(emptyList(),listOf(57600001L),true)}
    // Scheduler tests are synthetic: actual Android queries remain required.
    fun due(frame:Long,last:Long,count:Int=2,terminal:Boolean=false,now:Long=1L)=
      LabDLongPts.shouldSample(frame,last,now,10L,count,terminal)
    check(due(318L,-1L,count=0,now=10L))
    check(!due(20000L,318L))
    check(due(20000L,318L,now=10L))
    for(boundary in listOf(57600000L,115200000L)) {
      check(!due(boundary-16001L,boundary-32000L))
      check(due(boundary-16000L,boundary-32000L))
      check(!due(boundary-1L,boundary-16000L))
      check(!due(boundary,boundary-16000L,now=10L))
      check(due(boundary+1L,boundary-16000L))
      check(!due(boundary+2L,boundary+1L))
      check(due(boundary,boundary-16000L,terminal=true))
    }
    check(due(560638L,80638L,terminal=true))
    check(!due(560638L,560638L,terminal=true))
    check(!due(0L,-1L,count=0,terminal=true))
    check(!due(560638L,80638L,count=47,now=10L))
    check(due(560638L,80638L,count=47,terminal=true))
    check(!due(560638L,80638L,count=48,terminal=true))
    rejects{due(10L,11L)}
    println("LAB_D_LONG_PTS_BOUNDARY_TERMINAL_SCHEDULER_HOST_PASS")
    println("LAB_D_LONG_COMMITTED_PTS_COVERAGE_HOST_PASS")
    println("LAB_D_LONG_HARDWARE_PTS_V2_HOST_PASS")
    println("LAB_D_LONG_HARDWARE_PTS_HOST_PASS")
  }
}
