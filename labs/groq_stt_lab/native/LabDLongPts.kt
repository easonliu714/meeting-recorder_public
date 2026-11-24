package com.example.meeting_recorder.public_lab_v41.groq_stt_lab

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption

/** True Android AudioRecord hardware frame/time observations, independent of PCM ordinal. */
internal object LabDLongPts {
    data class Sample(val capturedFrames:Long,val hardwareFrames:Long?,val hardwareNs:Long?,val observedMonoNs:Long)
    private const val MAX_COUNT=48
    private const val MAX_FRAMES=144000000L
    private val rx=Regex("^longpts_[0-9]{6}[.]receipt$")
    private fun name(i:Int)="longpts_%06d.receipt".format(java.util.Locale.ROOT,i)
    private fun encode(s:Sample):ByteArray =
        "v1\t${s.capturedFrames}\t${s.hardwareFrames?:-1L}\t${s.hardwareNs?:-1L}\t${s.observedMonoNs}\n"
          .toByteArray(Charsets.US_ASCII)
    fun inspect(items:List<Sample>):String {
        if(items.isEmpty())return "NOT_VERIFIED"
        check(items.size<=MAX_COUNT){"LAB_D_LONG_PTS_LIMIT_HOLD"}
        var prev:Sample?=null
        for(s in items) {
            check(s.capturedFrames in 0..MAX_FRAMES &&
              s.observedMonoNs>0 && (s.hardwareFrames==null)==(s.hardwareNs==null) &&
              (s.hardwareFrames==null ||
               (s.hardwareFrames in 0..10000000000L &&
                s.hardwareNs!!>0 && s.hardwareNs!!<=s.observedMonoNs+5000000000L))) {
                "LAB_D_LONG_PTS_EVIDENCE_HOLD"
            }
            if(prev!=null)check(s.capturedFrames>prev.capturedFrames &&
                s.observedMonoNs>prev.observedMonoNs){"LAB_D_LONG_PTS_SEQUENCE_HOLD"}
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
                "crosses60" to (a.capturedFrames<57600000L && b.capturedFrames>=57600000L),
                "crosses120" to (a.capturedFrames<115200000L && b.capturedFrames>=115200000L),
                "state" to state
            )
        }
    }
    fun publish(folder:File,index:Int,s:Sample) {
        check(index in 1..MAX_COUNT){"LAB_D_LONG_PTS_LIMIT_HOLD"}
        inspect(listOf(s))
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
              && f.length() in 13L..120L){"LAB_D_LONG_PTS_READBACK_HOLD"}
            val str=f.readText(Charsets.US_ASCII)
            check(str.endsWith("\n")){"LAB_D_LONG_PTS_READBACK_HOLD"}
            val tokens=str.trimEnd('\n').split('\t')
            check(tokens.size==5 && tokens[0]=="v1"){"LAB_D_LONG_PTS_READBACK_HOLD"}
            val v=tokens.drop(1).map {it.toLongOrNull()?:error("LAB_D_LONG_PTS_READBACK_HOLD")}
            val sample=Sample(v[0],v[1].takeIf{it>=0},v[2].takeIf{it>=0},v[3])
            check(encode(sample).contentEquals(str.toByteArray(Charsets.US_ASCII))){"LAB_D_LONG_PTS_READBACK_HOLD"}
            sample
        }.also{inspect(it)}
    }
}
