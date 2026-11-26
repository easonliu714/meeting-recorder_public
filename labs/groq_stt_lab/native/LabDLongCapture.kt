package com.example.meeting_recorder.public_lab_v43.groq_stt_lab

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTimestamp
import android.media.MediaRecorder
import android.os.Build
import android.os.SystemClock
import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardCopyOption
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference

/**
 * Gate D real-time one-session 150min bounded capture.
 * 60min committed Part boundaries; genuine 120min clock belongs to FGS model.
 * Each physical PCM raw Part and its immutable WAV/SHA/receipt remain on disk.
 * Unlike v39's 24s fixture, NEVER use accelerated time or synthetic AudioTimestamp.
 */
internal object LabDLongCapture {
    private const val RATE=16000
    private const val PART_BYTES=115200000 // exact physical PCM16 60min, not wall clock
    private const val PART_LIMIT=3 // 60 + 60 + 30min
    private const val MAX_BYTES=288000000
    private const val PTS_INTERVAL_NS=300000000000L // five physical minutes
    private const val MIN_FREE=1250000000L // raw + sealed WAV coexist; 1.25GB free before START
    private const val REMAINING_SAFE=192L*1024*1024
    private val uuid=Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private fun regular(f:File)=Files.isRegularFile(f.toPath(),LinkOption.NOFOLLOW_LINKS)
        && f.absoluteFile==f.canonicalFile
    private fun base(context:Context,create:Boolean):File {
        check(Build.VERSION.SDK_INT>=26){"LAB_D_LONG_API_HOLD"}
        val dir=File(context.filesDir.canonicalFile,"lab_d_long_v1")
        if(create && !dir.exists())check(dir.mkdir()){"LAB_D_LONG_FOLDER_HOLD"}
        check(dir.isDirectory && dir.absoluteFile==dir.canonicalFile){"LAB_D_LONG_FOLDER_HOLD"}
        return dir
    }
    private fun snapshot(dir:File,id:UUID,verifyOriginal:Boolean=false):Map<String,Any> {
        val items=dir.listFiles()?:error("LAB_D_LONG_READBACK_HOLD")
        val hasCommitted=items.any{it.name.endsWith(".commit")}
        val finished=Files.exists(File(dir,"finished_v1.txt").toPath(),LinkOption.NOFOLLOW_LINKS)
        val proof=if(hasCommitted||finished)LabMultiPartProof(dir,id).recoverSnapshot() else null
        val parts=proof?.receipts?:emptyList()
        check(parts.size<=PART_LIMIT){"LAB_D_LONG_PART_LIMIT_HOLD"}
        if(verifyOriginal) parts.forEach { LabMultiPartProof(dir,id).verifyRaw(it) }
        val rx=Regex("^part_([0-9]{6})_inflight[.]pcm$")
        var tail=0L
        items.forEach{file->
            val m=rx.matchEntire(file.name)?:return@forEach
            val idx=m.groupValues[1].toInt()
            check(idx in 1..PART_LIMIT && regular(file) && file.length()<=PART_BYTES) {
                "LAB_D_LONG_TAIL_HOLD"
            }
            if(idx>parts.size)tail+=file.length()
        }
        check(proof?.finished!=true || tail==0L){"LAB_D_LONG_SEAL_HOLD"}
        val pts=LabDLongPts.read(dir)
        val status=LabDLongPts.inspect(pts)
        val cross=pts.any{it.capturedFrames<57600000L && it.hardwareFrames!=null} &&
            pts.any{it.capturedFrames>=57600000L && it.hardwareFrames!=null}
        return mapOf(
            "status" to when {
                proof?.finished==true -> "completed"
                parts.isEmpty()->"uncommitted"
                else->"interrupted"
            },
            "parts" to parts.map{p->mapOf("index" to p.index,"start" to p.start,
                "end" to p.end,"bytes" to p.bytes,"sha12" to p.sha.take(12),
                "sha256" to p.sha,"rawMatches" to verifyOriginal)},
            "tailBytes" to tail,
            "session" to id.toString(),
            "ptsCount" to pts.size,
            "ptsStatus" to status,
            "ptsIntervals" to LabDLongPts.crosswalk(pts),
            "ptsCoverage" to LabDLongPts.coverage(pts,parts.map{it.end},proof?.finished==true),
            "ptsObservations" to LabDLongPts.observations(pts),
            "ptsProvenance" to LabDLongPts.provenance(pts),
            "crossHourHardwareObserved" to cross,
            "hardwareFirst" to (pts.firstOrNull{it.hardwareFrames!=null}?.hardwareFrames?:-1L),
            "hardwareLast" to (pts.lastOrNull{it.hardwareFrames!=null}?.hardwareFrames?:-1L),
            "sourceIdentity" to "NOT_VERIFIED",
            "unaccelerated" to true,
            "hourPartFrames" to 57600000L
        )
    }
    fun recover(context:Context):Map<String,Any> {
        val folder=base(context,false)
        val pointer=File(folder,"latest_long_attempt_v1.txt")
        check(regular(pointer) && pointer.length()==36L){"LAB_D_LONG_POINTER_HOLD"}
        val name=pointer.readText(Charsets.US_ASCII)
        check(uuid.matches(name)){"LAB_D_LONG_POINTER_HOLD"}
        val dir=File(folder,name)
        check(dir.isDirectory && dir.absoluteFile==dir.canonicalFile){"LAB_D_LONG_POINTER_HOLD"}
        val result=snapshot(dir,UUID.fromString(name),true)
        check(pointer.readText(Charsets.US_ASCII)==name){"LAB_D_LONG_POINTER_HOLD"}
        return result
    }
    /** Resolve only the verified committed Part from the explicit current session. */
    fun previewFile(context:Context,session:String,index:Int,sha:String):File {
        check(uuid.matches(session) && index in 1..PART_LIMIT &&
            Regex("^[0-9a-f]{64}$").matches(sha)){"LAB_D_LONG_PLAYBACK_INPUT_HOLD"}
        val folder=base(context,false)
        val pointer=File(folder,"latest_long_attempt_v1.txt")
        check(regular(pointer) && pointer.length()==36L &&
            pointer.readText(Charsets.US_ASCII)==session){"LAB_D_LONG_PLAYBACK_SESSION_HOLD"}
        val dir=File(folder,session)
        check(dir.isDirectory && dir.absoluteFile==dir.canonicalFile){"LAB_D_LONG_PLAYBACK_SESSION_HOLD"}
        val wav=LabMultiPartProof(dir,UUID.fromString(session)).verifiedWav(index,sha)
        check(pointer.readText(Charsets.US_ASCII)==session){"LAB_D_LONG_PLAYBACK_SESSION_HOLD"}
        return wav
    }
    /**
     * mode 0=record; 1=interrupt (raw tail isolated); 2=user normal stop.
     * Separate serial disk thread avoids fsync/hash over 115MB on the mic thread.
     */
    fun capture(context:Context,mode:AtomicInteger,frames:AtomicInteger,
      committed:AtomicInteger):Map<String,Any> {
        val folder=base(context,true)
        check(folder.usableSpace>=MIN_FREE){"LAB_D_LONG_PREFLIGHT_SPACE_HOLD"}
        val id=UUID.randomUUID()
        val dir=File(folder,id.toString())
        check(dir.mkdir()){"LAB_D_LONG_FOLDER_HOLD"}
        val pointerTmp=File(folder,"latest_long_$id.tmp")
        check(pointerTmp.createNewFile()){"LAB_D_LONG_POINTER_HOLD"}
        FileOutputStream(pointerTmp).use{
            it.write(id.toString().toByteArray(Charsets.US_ASCII));it.fd.sync()
        }
        Files.move(pointerTmp.toPath(),File(folder,"latest_long_attempt_v1.txt").toPath(),
            StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        val min=AudioRecord.getMinBufferSize(RATE,AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT)
        check(min>0){"LAB_D_LONG_CONFIG_HOLD"}
        val recorder=AudioRecord(MediaRecorder.AudioSource.MIC,RATE,AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,maxOf(min,16384))
        // 8 MiB queue buffers up to 4 minutes of input while the 60min WAV is copied,
        // fsynced and SHA-verified. Never block mic on storage or discard data silently.
        val queue=ArrayBlockingQueue<ByteArray>(2048)
        val done=AtomicBoolean(false)
        val normal=AtomicBoolean(false)
        val diskError=AtomicReference<Exception?>(null)
        val worker=Thread {
            try {
                LabMultiPartSink(dir,id,PART_BYTES,PART_LIMIT,
                    spaceOk={dir.usableSpace>=REMAINING_SAFE},
                    onCommit={committed.set(it)}).use { sink ->
                    while(!done.get() || queue.isNotEmpty()) {
                        val bytes=queue.poll(100,TimeUnit.MILLISECONDS)
                        if(bytes!=null)sink.accept(bytes)
                    }
                    sink.finish(normal.get())
                }
            } catch(e:Exception){diskError.set(e)}
        }
        var captureError:Exception?=null
        var workerStarted=false
        try {
            check(recorder.state==AudioRecord.STATE_INITIALIZED){"LAB_D_LONG_INIT_HOLD"}
            if(mode.get()!=0)return snapshot(dir,id)
            recorder.startRecording()
            check(recorder.recordingState==AudioRecord.RECORDSTATE_RECORDING) {
                "LAB_D_LONG_START_HOLD"
            }
            worker.start();workerStarted=true
            val start=SystemClock.elapsedRealtimeNanos()
            val buffer=ByteArray(4096)
            var total=0
            var nextPtsNs=0L
            var index=0
            val recorderLifetime=UUID.randomUUID().toString()
            while(total<MAX_BYTES && mode.get()==0) {
                diskError.get()?.let{throw it}
                check(SystemClock.elapsedRealtimeNanos()-start <
                  (LabDLongClock.CAP_MS+120000L)*1000000L){"LAB_D_LONG_DURATION_HOLD"}
                val n=recorder.read(buffer,0,minOf(buffer.size,MAX_BYTES-total),
                    AudioRecord.READ_NON_BLOCKING)
                check(n>=0 && n%2==0){"LAB_D_LONG_READ_HOLD"}
                if(n==0){Thread.sleep(10);continue}
                check(queue.offer(buffer.copyOf(n))){"LAB_D_LONG_QUEUE_HOLD"}
                total+=n
                frames.set(total/2)
                val now=SystemClock.elapsedRealtimeNanos()
                if(now>=nextPtsNs && index<48) {
                    // Genuine Android timestamp or explicit unavailable sample;
                    // neither total/2 nor WAV Part ordinal is a hardware timestamp.
                    val timestamp=AudioTimestamp()
                    // Bracket the genuine hardware query on CLOCK_MONOTONIC, and
                    // independently bracket elapsedRealtime to detect possible suspend.
                    val beforeElapsed=SystemClock.elapsedRealtimeNanos()
                    val beforeMono=System.nanoTime()
                    val result=try {
                        recorder.getTimestamp(timestamp,AudioTimestamp.TIMEBASE_MONOTONIC)
                    } catch(_:Exception){AudioRecord.ERROR_INVALID_OPERATION}
                    val afterMono=System.nanoTime()
                    val afterElapsed=SystemClock.elapsedRealtimeNanos()
                    val hf=if(result==AudioRecord.SUCCESS && timestamp.nanoTime>0 &&
                        timestamp.framePosition>=0)timestamp.framePosition else null
                    val hn=if(hf==null)null else timestamp.nanoTime
                    LabDLongPts.publish(dir,++index,
                        LabDLongPts.Sample(total.toLong()/2,hf,hn,beforeElapsed,
                            LabDLongPts.Observation(id.toString(),recorderLifetime,
                                beforeMono,afterMono,beforeElapsed,afterElapsed)))
                    // A second genuine observation at ~5s enables bounded short UAT.
                    // Subsequent samples retain the existing 5-minute cadence and cap.
                    nextPtsNs=afterElapsed+if(index==1)5000000000L else PTS_INTERVAL_NS
                }
            }
            normal.set(mode.get()==2 || (total==MAX_BYTES && mode.get()==0))
        } catch(e:Exception) { captureError=e;normal.set(false) }
        finally {
            try {
                if(recorder.recordingState==AudioRecord.RECORDSTATE_RECORDING)recorder.stop()
            }catch(e:Exception){
                normal.set(false)
                if(captureError==null)captureError=e
            } finally {
                recorder.release();done.set(true)
                if(workerStarted) {
                    var interrupted=false
                    while(worker.isAlive) {
                        try{worker.join()}catch(_:InterruptedException){
                            interrupted=true;normal.set(false)
                        }
                    }
                    if(interrupted)Thread.currentThread().interrupt()
                }
            }
        }
        diskError.get()?.let{throw it}
        captureError?.let{throw it}
        return snapshot(dir,id)
    }
}
