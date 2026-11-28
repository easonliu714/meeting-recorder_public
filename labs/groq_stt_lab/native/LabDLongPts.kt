package com.example.meeting_recorder.public_lab_v45.groq_stt_lab

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption

/** True Android AudioRecord hardware frame/time observations, independent of PCM ordinal. */
internal object LabDLongPts {
    // v1 observedMonoNs is historically elapsedRealtimeNanos, NOT CLOCK_MONOTONIC.
    data class Observation(val session:String,val recorder:String,val beforeMonoNs:Long,
        val afterMonoNs:Long,val beforeElapsedNs:Long,val afterElapsedNs:Long)
    data class Sample(val capturedFrames:Long,val hardwareFrames:Long?,val hardwareNs:Long?,
        val observedMonoNs:Long,val observation:Observation?=null)
    private const val WINDOW_LIMIT_NS=50000000L // diagnostic 50ms, not calibration
    private const val LAG_LIMIT_NS=2000000000L // diagnostic 2s, not a loss bound
    private val idPattern=Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private fun observationState(s:Sample):String {
        val o=s.observation?:return "LEGACY_TIMEBASE_NOT_VERIFIED"
        val h=s.hardwareNs?:return "HARDWARE_UNAVAILABLE_NOT_VERIFIED"
        return when {
            h>o.afterMonoNs -> "FUTURE_TIMESTAMP_HOLD"
            o.afterMonoNs-o.beforeMonoNs>WINDOW_LIMIT_NS ||
                o.afterElapsedNs-o.beforeElapsedNs>WINDOW_LIMIT_NS -> "WIDE_WINDOW_HOLD"
            o.afterMonoNs-h>LAG_LIMIT_NS -> "STALE_TIMESTAMP_HOLD"
            else -> "BOUNDED_OBSERVATION_NOT_GAP_FREE"
        }
    }
    // Compare deltas between brackets, not absolute unlike-clock timestamps.
    // Positive elapsed-minus-monotonic excess may indicate suspend; it cannot prove loss.
    private fun intervalClock(a:Sample,b:Sample):String {
        val x=a.observation?:return "LEGACY_TIMEBASE_NOT_VERIFIED"
        val y=b.observation?:return "LEGACY_TIMEBASE_NOT_VERIFIED"
        if(y.beforeMonoNs<x.afterMonoNs || y.beforeElapsedNs<x.afterElapsedNs)
            return "CLOCK_SEQUENCE_HOLD"
        val low=(y.beforeElapsedNs-x.afterElapsedNs)-(y.afterMonoNs-x.beforeMonoNs)
        val high=(y.afterElapsedNs-x.beforeElapsedNs)-(y.beforeMonoNs-x.afterMonoNs)
        return when {
            low>WINDOW_LIMIT_NS -> "POSSIBLE_SUSPEND_HOLD"
            high< -WINDOW_LIMIT_NS -> "CLOCK_DISCONTINUITY_HOLD"
            observationState(a)!="BOUNDED_OBSERVATION_NOT_GAP_FREE" ||
                observationState(b)!="BOUNDED_OBSERVATION_NOT_GAP_FREE" -> "OBSERVATION_NOT_VERIFIED"
            else -> "BOUNDED_INTERVAL_NOT_GAP_FREE"
        }
    }
    fun observations(items:List<Sample>):List<Map<String,Any?>> {
        inspect(items)
        return items.map { s ->
            val o=s.observation
            mapOf("version" to if(o==null)1 else 2,
                "pcmFrame" to s.capturedFrames,"state" to observationState(s),
                "monoWindowNs" to o?.let{it.afterMonoNs-it.beforeMonoNs},
                "elapsedWindowNs" to o?.let{it.afterElapsedNs-it.beforeElapsedNs},
                "lagLowerNs" to o?.let{v->s.hardwareNs?.let{v.beforeMonoNs-it}},
                "lagUpperNs" to o?.let{v->s.hardwareNs?.let{v.afterMonoNs-it}})
        }
    }
    fun provenance(items:List<Sample>):String {
        inspect(items)
        return if(items.isNotEmpty() && items.all{it.observation!=null})
            "LOCAL_SESSION_RECORDER_BOUND_NOT_ATTESTED" else "NOT_VERIFIED"
    }
    private const val MAX_COUNT=48
    private const val MAX_FRAMES=144000000L
    private val physicalBoundaries=listOf(57600000L,115200000L)
    private const val BOUNDARY_LEAD_FRAMES=16000L // one second at configured 16 kHz

    /** Schedule actual queries, never generate positions or claim a committed boundary. */
    fun shouldSample(capturedFrames:Long,lastSampleFrames:Long,nowNs:Long,
        nextPeriodicNs:Long,count:Int,terminal:Boolean=false):Boolean {
        check(capturedFrames in 0..MAX_FRAMES && lastSampleFrames in -1L..capturedFrames &&
            count in 0..MAX_COUNT){"LAB_D_LONG_PTS_SCHEDULE_HOLD"}
        if(capturedFrames==0L || capturedFrames<=lastSampleFrames || count>=MAX_COUNT)return false
        if(terminal)return true // reserve one slot for a normal-stop endpoint
        if(count>=MAX_COUNT-1)return false
        // A strict before/after pair can straddle a boundary; a sample exactly
        // at a boundary cannot establish such a pair. Terminal samples are exempt.
        if(capturedFrames in physicalBoundaries)return false
        val nearBoundary=physicalBoundaries.any { boundary ->
            (capturedFrames>=boundary-BOUNDARY_LEAD_FRAMES && capturedFrames<boundary &&
                lastSampleFrames<boundary-BOUNDARY_LEAD_FRAMES) ||
            (capturedFrames>boundary && lastSampleFrames<boundary)
        }
        return nowNs>=nextPeriodicNs || nearBoundary
    }
    private val rx=Regex("^longpts_[0-9]{6}[.]receipt$")
    private fun name(i:Int)="longpts_%06d.receipt".format(java.util.Locale.ROOT,i)
    private fun encode(s:Sample):ByteArray {
        val o=s.observation
        val common="${s.capturedFrames}\t${s.hardwareFrames?:-1L}\t${s.hardwareNs?:-1L}\t${s.observedMonoNs}"
        return (if(o==null)"v1\t$common\n" else
            "v2\t$common\t${o.session}\t${o.recorder}\t${o.beforeMonoNs}\t${o.afterMonoNs}\t${o.beforeElapsedNs}\t${o.afterElapsedNs}\n")
            .toByteArray(Charsets.US_ASCII)
    }
    fun inspect(items:List<Sample>):String {
        if(items.isEmpty())return "NOT_VERIFIED"
        check(items.size<=MAX_COUNT){"LAB_D_LONG_PTS_LIMIT_HOLD"}
        var prev:Sample?=null
        for(s in items) {
            check(s.capturedFrames in 0..MAX_FRAMES &&
              s.observedMonoNs>0 && (s.hardwareFrames==null)==(s.hardwareNs==null) &&
              (s.hardwareFrames==null ||
               (s.hardwareFrames in 0..10000000000L &&
                s.hardwareNs!!>0))) {
                "LAB_D_LONG_PTS_EVIDENCE_HOLD"
            }
            val o=s.observation
            if(o!=null)check(idPattern.matches(o.session)&&idPattern.matches(o.recorder)&&
                o.beforeMonoNs>0&&o.afterMonoNs>=o.beforeMonoNs&&
                o.beforeElapsedNs==s.observedMonoNs&&o.afterElapsedNs>=o.beforeElapsedNs) {
                "LAB_D_LONG_PTS_OBSERVATION_HOLD"
            }
            if(prev!=null) {
                check(s.capturedFrames>prev.capturedFrames &&
                    s.observedMonoNs>prev.observedMonoNs){"LAB_D_LONG_PTS_SEQUENCE_HOLD"}
                val prior=prev.observation
                check((prior==null)==(o==null) &&
                    (prior==null || (prior.session==o?.session && prior.recorder==o?.recorder))) {
                    "LAB_D_LONG_PTS_PROVENANCE_HOLD"
                }
            }
            prev=s
        }
        if(items.size<2 || items.any{it.hardwareFrames==null})return "NOT_VERIFIED"
        for(i in 1 until items.size) {
            val a=items[i-1];val b=items[i]
            if(b.hardwareFrames!!<=a.hardwareFrames!! || b.hardwareNs!!<=a.hardwareNs!!)
                return "LAB_D_LONG_PTS_RESET_OR_STALL_HOLD"
            val physical=b.capturedFrames-a.capturedFrames
            val native=b.hardwareFrames-a.hardwareFrames
            if(kotlin.math.abs(physical-native)>32000L)
                return "LAB_D_LONG_PTS_UNALIGNED_HOLD"
        }
        if(items.first().observation!=null &&
            (items.any{observationState(it)!="BOUNDED_OBSERVATION_NOT_GAP_FREE"} ||
            items.zipWithNext().any{intervalClock(it.first,it.second)!="BOUNDED_INTERVAL_NOT_GAP_FREE"}))
            return "LAB_D_LONG_PTS_TIMEBASE_HOLD"
        return "HARDWARE_PTS_OBSERVED_NOT_GAP_FREE"
    }
    /**
     * Adjacent actual receipts only. A signed frame residual is an observation,
     * not proof of the cause (buffer latency, clock drift, loss, or overlap).
     * v1 observedMonoNs is elapsedRealtimeNanos; never subtract it directly
     * from AudioTimestamp.TIMEBASE_MONOTONIC. Preserve every unknown interval.
     */
    fun crosswalk(items:List<Sample>):List<Map<String,Any?>> {
        inspect(items) // same fail-closed validation as existing receipt readback
        return items.zipWithNext().map { (a,b) ->
            val pcm=b.capturedFrames-a.capturedFrames
            val native=if(a.hardwareFrames!=null && b.hardwareFrames!=null)
                b.hardwareFrames-a.hardwareFrames else null
            val hardwareNs=if(a.hardwareNs!=null && b.hardwareNs!=null)
                b.hardwareNs-a.hardwareNs else null
            val residual=native?.minus(pcm)
            // Configured 16 kHz: exactly 62,500 ns/frame. This is a
            // diagnostic comparison, not a calibrated hardware error bound.
            val clockResidual=if(native!=null && hardwareNs!=null &&
                native>0 && hardwareNs>0) hardwareNs-native*62500L else null
            val state=when {
                native==null || hardwareNs==null -> "UNKNOWN"
                native<=0 || hardwareNs<=0 -> "RESET_OR_STALL"
                residual!!>32000L -> "POSSIBLE_GAP"
                residual < -32000L -> "POSSIBLE_OVERLAP"
                kotlin.math.abs(clockResidual!!)>2000000000L -> "HARDWARE_CLOCK_UNALIGNED"
                else -> "WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE"
            }
            mapOf(
                "pcmStart" to a.capturedFrames,
                "pcmEnd" to b.capturedFrames,
                "pcmDelta" to pcm,
                "hardwareDelta" to native,
                "hardwareMinusPcm" to residual,
                "hardwareElapsedNs" to hardwareNs,
                "hardwareClockMinusFramesNs" to clockResidual,
                "observedElapsedNs" to (b.observedMonoNs-a.observedMonoNs),
                "clockObservationState" to intervalClock(a,b),
                "crosses60" to (a.capturedFrames<57600000L && b.capturedFrames>=57600000L),
                "crosses120" to (a.capturedFrames<115200000L && b.capturedFrames>=115200000L),
                "state" to state
            )
        }
    }
    /**
     * Partition only the verified committed PCM extent. Adjacent receipt pairs
     * are endpoint observations, NOT continuous hardware or acoustic coverage.
     * A pair extending into an uncommitted tail cannot support committed coverage.
     * Never interpolate hardware positions at a Part boundary.
     */
    fun coverage(items:List<Sample>,partEnds:List<Long>,finished:Boolean):Map<String,Any> {
        val intervals=crosswalk(items)
        check(partEnds.size<=3 && (!finished||partEnds.isNotEmpty()) &&
            partEnds.zipWithNext().all{it.second>it.first} &&
            partEnds.all{it in 1..MAX_FRAMES}){"LAB_D_LONG_PTS_COVERAGE_HOLD"}
        val committedEnd=partEnds.lastOrNull()?:0L
        val outside=items.count{it.capturedFrames>committedEnd}
        check(!finished||outside==0){"LAB_D_LONG_PTS_EXTENT_HOLD"}
        fun pairState(p:Map<String,Any?>):String {
            val end=p["pcmEnd"] as Long
            return when {
                end>committedEnd -> "PAIR_OUTSIDE_COMMITTED_NOT_VERIFIED"
                p["state"]=="WITHIN_DIAGNOSTIC_BOUND_NOT_GAP_FREE" &&
                    p["clockObservationState"]=="BOUNDED_INTERVAL_NOT_GAP_FREE" ->
                    "BOUNDED_PAIR_NOT_GAP_FREE"
                p["state"]=="UNKNOWN" ||
                    p["clockObservationState"]=="LEGACY_TIMEBASE_NOT_VERIFIED" ||
                    p["clockObservationState"]=="OBSERVATION_NOT_VERIFIED" ->
                    "PAIR_NOT_VERIFIED"
                else -> "PAIR_DIAGNOSTIC_HOLD"
            }
        }
        var start=0L
        var totalBounded=0L
        val parts=partEnds.mapIndexed { i,end ->
            check(end-start in 1..57600000L){"LAB_D_LONG_PTS_COVERAGE_HOLD"}
            var cursor=start
            var bounded=0L
            val segments=mutableListOf<Map<String,Any>>()
            fun segment(a:Long,b:Long,state:String) {
                if(b<=a)return
                check(a==cursor && b<=end){"LAB_D_LONG_PTS_COVERAGE_HOLD"}
                segments.add(mapOf("start" to a,"end" to b,"state" to state))
                if(state=="BOUNDED_PAIR_NOT_GAP_FREE")bounded+=b-a
                cursor=b
            }
            for(p in intervals) {
                val a=maxOf(start,p["pcmStart"] as Long)
                val b=minOf(end,p["pcmEnd"] as Long)
                if(a>=b)continue
                if(cursor<a)segment(cursor,a,"UNOBSERVED_NOT_VERIFIED")
                segment(a,b,pairState(p))
            }
            if(cursor<end)segment(cursor,end,"UNOBSERVED_NOT_VERIFIED")
            check(cursor==end){"LAB_D_LONG_PTS_COVERAGE_HOLD"}
            val result=mapOf("index" to i+1,"start" to start,"end" to end,
                "boundedFrames" to bounded,"unknownFrames" to end-start-bounded,
                "segments" to segments)
            totalBounded+=bounded
            start=end
            result
        }
        // Only actual internal committed boundaries, not nominal 60/120min
        // milestones or the final end of the last committed Part.
        val boundaries=partEnds.dropLast(1).map { frame ->
            val p=intervals.firstOrNull{(it["pcmStart"] as Long)<frame &&
                (it["pcmEnd"] as Long)>frame}
            val state=if(p==null) {
                if(items.any{it.capturedFrames==frame})"BOUNDARY_SAMPLE_ONLY_NOT_VERIFIED"
                else "BOUNDARY_UNOBSERVED_NOT_VERIFIED"
            } else pairState(p)
            mapOf("frame" to frame,"state" to state,
                "pairStart" to p?.get("pcmStart"),"pairEnd" to p?.get("pcmEnd"))
        }
        return mapOf("committedFrames" to committedEnd,
            "boundedFrames" to totalBounded,"unknownFrames" to committedEnd-totalBounded,
            "outsideCommittedSamples" to outside,"parts" to parts,"boundaries" to boundaries,
            "continuity" to "NOT_VERIFIED")
    }

    // This is a local consistency ledger, not cryptographic attestation of the
    // recorder or protection against an actor able to rewrite all local files.
    private const val SESSION_RECORD="capture_session_v1.txt"
    private const val SEALED_MANIFEST="capture_manifest_v1.txt"
    private fun exists(f:File)=Files.exists(f.toPath(),LinkOption.NOFOLLOW_LINKS)
    private fun localFile(folder:File,name:String):File {
        check(folder.isDirectory && folder.absoluteFile==folder.canonicalFile &&
            idPattern.matches(folder.name)){"LAB_D_LONG_MANIFEST_HOLD"}
        return File(folder,name)
    }
    private fun readLocal(f:File,limit:Long):ByteArray {
        check(Files.isRegularFile(f.toPath(),LinkOption.NOFOLLOW_LINKS) &&
            f.absoluteFile==f.canonicalFile && f.length() in 1L..limit){
            "LAB_D_LONG_MANIFEST_HOLD"
        }
        return f.readBytes().also{check(it.size.toLong()==f.length()){
            "LAB_D_LONG_MANIFEST_HOLD"
        }}
    }
    private fun createLocal(f:File,bytes:ByteArray) {
        check(!exists(f)){"LAB_D_LONG_MANIFEST_EXISTS_HOLD"}
        try {
            FileChannel.open(f.toPath(),StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE).use { ch ->
                val b=ByteBuffer.wrap(bytes)
                while(b.hasRemaining())check(ch.write(b)>0){"LAB_D_LONG_MANIFEST_WRITE_HOLD"}
                ch.force(true)
            }
        } catch(e:java.io.IOException) {
            throw IllegalStateException("LAB_D_LONG_MANIFEST_WRITE_HOLD",e)
        }
        check(readLocal(f,16384L).contentEquals(bytes)){"LAB_D_LONG_MANIFEST_HOLD"}
    }
    fun beginManifest(folder:File,recorder:String) {
        check(idPattern.matches(recorder)){"LAB_D_LONG_MANIFEST_HOLD"}
        val bytes="v1\t${folder.name}\t$recorder\n".toByteArray(Charsets.US_ASCII)
        createLocal(localFile(folder,SESSION_RECORD),bytes)
    }
    /** Canonical records are supplied only by the already verified Part/WAV proof.
     * Raw PCM is compared byte-for-byte with those WAVs by the caller.
     * The final ledger binds exact ordered receipt bytes, verified Part descriptors,
     * session and recorder lifetime. Missing final publication stays NOT_VERIFIED.
     */
    fun manifestState(folder:File,items:List<Sample>,partRecords:List<String>,
        completed:Boolean,seal:Boolean=false):String {
        inspect(items)
        val start=localFile(folder,SESSION_RECORD)
        val target=localFile(folder,SEALED_MANIFEST)
        if(!exists(start)) {
            check(!exists(target)&&!seal){"LAB_D_LONG_MANIFEST_HOLD"}
            return "LOCAL_MANIFEST_ABSENT_NOT_VERIFIED"
        }
        val binding=readLocal(start,128L)
        val text=binding.toString(Charsets.US_ASCII)
        val fields=text.trimEnd('\n').split('\t')
        check(fields.size==3 && fields[0]=="v1" && fields[1]==folder.name &&
            idPattern.matches(fields[2]) &&
            binding.contentEquals("v1\t${folder.name}\t${fields[2]}\n".toByteArray(Charsets.US_ASCII))){
            "LAB_D_LONG_MANIFEST_HOLD"
        }
        check(items.all{it.observation?.session==folder.name &&
            it.observation?.recorder==fields[2]}){"LAB_D_LONG_MANIFEST_BINDING_HOLD"}
        if(!completed) {
            check(!exists(target)&&!seal){"LAB_D_LONG_MANIFEST_HOLD"}
            return "LOCAL_MANIFEST_UNSEALED_NOT_VERIFIED"
        }
        check(partRecords.size in 1..3 && partRecords.all{
            it.length<=256 && Regex("^[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9a-f]{64}$").matches(it)
        }){"LAB_D_LONG_MANIFEST_HOLD"}
        val md=java.security.MessageDigest.getInstance("SHA-256")
        md.update(binding)
        for(record in partRecords)md.update("part\t$record\n".toByteArray(Charsets.US_ASCII))
        for(sample in items){md.update("pts\t".toByteArray(Charsets.US_ASCII));md.update(encode(sample))}
        val hash=md.digest().joinToString(""){"%02x".format(it)}
        val expected="v1\t${folder.name}\t${fields[2]}\t${partRecords.size}\t${items.size}\t$hash\n"
            .toByteArray(Charsets.US_ASCII)
        if(seal)createLocal(target,expected)
        if(!exists(target))return "LOCAL_MANIFEST_MISSING_NOT_VERIFIED"
        check(readLocal(target,512L).contentEquals(expected)){"LAB_D_LONG_MANIFEST_MISMATCH_HOLD"}
        return "LOCAL_MANIFEST_MATCH_NOT_ATTESTED"
    }

    fun publish(folder:File,index:Int,s:Sample) {
        check(index in 1..MAX_COUNT){"LAB_D_LONG_PTS_LIMIT_HOLD"}
        inspect(listOf(s))
        if(s.observation!=null)check(s.observation.session==folder.name){
            "LAB_D_LONG_PTS_PROVENANCE_HOLD"
        }
        val target=File(folder,name(index))
        val bytes=encode(s)
        check(!Files.exists(target.toPath(),LinkOption.NOFOLLOW_LINKS)){"LAB_D_LONG_PTS_EXISTS_HOLD"}
        try {
            FileChannel.open(target.toPath(),StandardOpenOption.CREATE_NEW,
              StandardOpenOption.WRITE).use {ch->
              val b=ByteBuffer.wrap(bytes)
              while(b.hasRemaining())check(ch.write(b)>0){"LAB_D_LONG_PTS_WRITE_HOLD"}
              ch.force(true)
            }
        } catch(e:java.io.IOException){throw IllegalStateException("LAB_D_LONG_PTS_WRITE_HOLD",e)}
        check(Files.isRegularFile(target.toPath(),LinkOption.NOFOLLOW_LINKS)
            && target.length()==bytes.size.toLong()
            && target.readBytes().contentEquals(bytes)){"LAB_D_LONG_PTS_READBACK_HOLD"}
    }
    fun read(folder:File):List<Sample> {
        val entries=folder.listFiles()?:error("LAB_D_LONG_PTS_READBACK_HOLD")
        val files=entries.filter{rx.matches(it.name)}.sortedBy{it.name}
        check(files.size<=MAX_COUNT){"LAB_D_LONG_PTS_LIMIT_HOLD"}
        return files.mapIndexed {i,f->
            check(f.name==name(i+1) && Files.isRegularFile(f.toPath(),LinkOption.NOFOLLOW_LINKS)
              && f.length() in 13L..512L){"LAB_D_LONG_PTS_READBACK_HOLD"}
            val str=f.readText(Charsets.US_ASCII)
            check(str.endsWith("\n")){"LAB_D_LONG_PTS_READBACK_HOLD"}
            val tokens=str.trimEnd('\n').split('\t')
            check((tokens.size==5 && tokens[0]=="v1") ||
                (tokens.size==11 && tokens[0]=="v2")){"LAB_D_LONG_PTS_READBACK_HOLD"}
            fun number(i:Int)=tokens[i].toLongOrNull()?:error("LAB_D_LONG_PTS_READBACK_HOLD")
            val o=if(tokens[0]=="v2")Observation(tokens[5],tokens[6],number(7),
                number(8),number(9),number(10)) else null
            if(o!=null)check(o.session==folder.name){"LAB_D_LONG_PTS_PROVENANCE_HOLD"}
            val sample=Sample(number(1),number(2).takeIf{it>=0},number(3).takeIf{it>=0},number(4),o)
            check(encode(sample).contentEquals(str.toByteArray(Charsets.US_ASCII))){"LAB_D_LONG_PTS_READBACK_HOLD"}
            sample
        }.also{inspect(it)}
    }
}
