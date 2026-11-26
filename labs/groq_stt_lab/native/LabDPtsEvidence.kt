package com.example.meeting_recorder.public_lab_v43.groq_stt_lab

import java.io.File
import java.nio.ByteBuffer
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption

/**
 * D stage-1 hardware-only evidence. PCM indices are never substituted for
 * AudioRecord framePosition. Even an aligned pair cannot prove gap-free speech.
 * These small, private, immutable receipts contain no sound or paths.
 */
internal object LabDPtsEvidence {
    data class Sample(val capturedFrames:Long, val hardwareFrames:Long?,
        val hardwareNs:Long?, val observedMonoNs:Long)

    private const val LIMIT=16
    private const val MAX_NATIVE_FRAME=1000000000L
    private fun hold():Nothing = error("LAB_D_PTS_EVIDENCE_HOLD")
    fun inspect(items:List<Sample>):String {
        if (items.isEmpty()) return "NOT_VERIFIED"
        if (items.size>LIMIT) hold()
        var prev:Sample?=null
        for(s in items) {
            if(s.capturedFrames<0 || s.capturedFrames>384000 ||
               s.observedMonoNs<=0 || (s.hardwareFrames==null)!=(s.hardwareNs==null) ||
               (s.hardwareFrames!=null && (s.hardwareFrames<0 || s.hardwareFrames>MAX_NATIVE_FRAME ||
                    s.hardwareNs!!<=0 || s.hardwareNs!!>s.observedMonoNs+5000000000L))) hold()
            if(prev!=null && (s.capturedFrames<=prev.capturedFrames ||
               s.observedMonoNs<=prev.observedMonoNs)) hold()
            prev=s
        }
        if(items.any{it.hardwareFrames==null} || items.size<2) return "NOT_VERIFIED"
        for(i in 1 until items.size) {
            val a=items[i-1];val b=items[i]
            if(b.hardwareFrames!!<=a.hardwareFrames!! || b.hardwareNs!!<=a.hardwareNs!!)
                return "LAB_D_PTS_RESET_OR_STALL_HOLD"
            val deltaCapture=b.capturedFrames-a.capturedFrames
            val deltaHardware=b.hardwareFrames-a.hardwareFrames
            if(kotlin.math.abs(deltaCapture-deltaHardware)>32000L)
                return "LAB_D_PTS_UNALIGNED_HOLD"
        }
        return "HARDWARE_PTS_OBSERVED_NOT_GAP_FREE"
    }
    private fun name(i:Int)="pts_%06d.receipt".format(java.util.Locale.ROOT,i)
    private fun encode(s:Sample):ByteArray =
        "v1\t${s.capturedFrames}\t${s.hardwareFrames?:-1L}\t${s.hardwareNs?:-1L}\t${s.observedMonoNs}\n"
            .toByteArray(Charsets.US_ASCII)
    fun publish(folder:File,i:Int,s:Sample) {
        check(i in 1..LIMIT) { "LAB_D_PTS_LIMIT_HOLD" }
        inspect(listOf(s))
        val target=File(folder,name(i))
        check(!Files.exists(target.toPath(),LinkOption.NOFOLLOW_LINKS)) {
            "LAB_D_PTS_EXISTS_HOLD"
        }
        val bytes=encode(s)
        try {
            FileChannel.open(target.toPath(),StandardOpenOption.CREATE_NEW,
                StandardOpenOption.WRITE).use { ch ->
                val buf=ByteBuffer.wrap(bytes)
                while(buf.hasRemaining()) check(ch.write(buf)>0){"LAB_D_PTS_WRITE_HOLD"}
                ch.force(true)
            }
        } catch(e:java.io.IOException) {
            throw IllegalStateException("LAB_D_PTS_WRITE_HOLD",e)
        }
        check(Files.isRegularFile(target.toPath(),LinkOption.NOFOLLOW_LINKS) &&
              target.length()==bytes.size.toLong() &&
              target.readBytes().contentEquals(bytes)){"LAB_D_PTS_READBACK_HOLD"}
    }
    fun read(folder:File):List<Sample> {
        val entries=folder.listFiles()?:error("LAB_D_PTS_READBACK_HOLD")
        val pts=entries.filter{Regex("^pts_[0-9]{6}[.]receipt$").matches(it.name)}
            .sortedBy{it.name}
        check(pts.size<=LIMIT){"LAB_D_PTS_LIMIT_HOLD"}
        return pts.mapIndexed { i,f ->
            check(f.name==name(i+1) &&
                Files.isRegularFile(f.toPath(),LinkOption.NOFOLLOW_LINKS) &&
                f.length() in 13L..120L){"LAB_D_PTS_READBACK_HOLD"}
            val t=f.readText(Charsets.US_ASCII)
            check(t.endsWith("\n")){"LAB_D_PTS_READBACK_HOLD"}
            val fields=t.trimEnd('\n').split('\t')
            check(fields.size==5 && fields[0]=="v1"){"LAB_D_PTS_READBACK_HOLD"}
            val nums=fields.drop(1).map{
                it.toLongOrNull()?:error("LAB_D_PTS_READBACK_HOLD")
            }
            val sample=Sample(nums[0],nums[1].takeIf{it>=0},nums[2].takeIf{it>=0},nums[3])
            check(encode(sample).contentEquals(t.toByteArray(Charsets.US_ASCII))) {
                "LAB_D_PTS_READBACK_HOLD"
            }
            sample
        }.also{inspect(it)}
    }
}
