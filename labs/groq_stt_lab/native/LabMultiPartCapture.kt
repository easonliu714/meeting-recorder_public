package com.example.meeting_recorder.public_lab_v39.groq_stt_lab

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

/** Independent foreground-only Gate A fixture. Service lifecycle belongs to B. */
internal object LabMultiPartCapture {
    private const val RATE=16000
    private const val PART_COUNT=4
    private const val PART_BYTES=RATE*2*6
    private const val MAX_BYTES=PART_BYTES*PART_COUNT
    private val uuid=Regex("^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
    private fun guard() { check(Build.VERSION.SDK_INT>=26) { "LAB_MULTI_ANDROID_API_HOLD" } }
    private fun parent(context:Context,create:Boolean):File {
        val p=File(context.filesDir.canonicalFile,"lab_multi_part_v1")
        if(create && !p.exists()) check(p.mkdir()) { "LAB_MULTI_STORAGE_HOLD" }
        check(p.isDirectory && p.absoluteFile==p.canonicalFile) { "LAB_MULTI_MISSING_HOLD" }
        return p
    }
    private fun regular(f:File)=Files.isRegularFile(f.toPath(),LinkOption.NOFOLLOW_LINKS) && f.absoluteFile==f.canonicalFile
    private fun snapshot(folder:File,id:UUID):Map<String,Any> {
        val entries=folder.listFiles() ?: error("LAB_MULTI_STORAGE_HOLD")
        val hasCommit=entries.any { it.name.endsWith(".commit") }
        val hasTerminal=Files.exists(File(folder,"finished_v1.txt").toPath(),LinkOption.NOFOLLOW_LINKS)
        val recovery=if(hasCommit||hasTerminal) LabMultiPartProof(folder,id).recoverSnapshot() else null
        val receipts=recovery?.receipts ?: emptyList()
        val tailPattern=Regex("^part_([0-9]{6})_inflight[.]pcm$")
        var tailBytes=0L
        for(f in entries) {
            val m=tailPattern.matchEntire(f.name) ?: continue
            val index=m.groupValues[1].toInt()
            check(index in 1..PART_COUNT && regular(f) && f.length()<=PART_BYTES) { "LAB_MULTI_TAIL_HOLD" }
            if(index>receipts.size) tailBytes+=f.length()
        }
        check(receipts.size<=PART_COUNT && (recovery?.finished!=true || tailBytes==0L)) { "LAB_MULTI_TAIL_HOLD" }
        val marker=File(folder,"d_pts_mode_v1.txt")
        val isD=Files.exists(marker.toPath(),LinkOption.NOFOLLOW_LINKS)
        if(isD) check(regular(marker) && marker.readText(Charsets.US_ASCII)=="v1\n") {
            "LAB_D_PTS_MODE_HOLD"
        }
        val pts=if(isD) LabDPtsEvidence.read(folder) else emptyList()
        val ptsState=if(isD) LabDPtsEvidence.inspect(pts) else "NOT_APPLICABLE"
        return mapOf("status" to when {
            recovery?.finished==true -> "completed"
            receipts.isEmpty() -> "uncommitted"
            else -> "interrupted"
        }, "parts" to receipts.map { r -> mapOf("index" to r.index,"start" to r.start,
            "end" to r.end,"bytes" to r.bytes,"sha12" to r.sha.take(12)) }, "tailBytes" to tailBytes,
            "dMode" to isD, "dSession" to (if(isD)id.toString() else "NONE"),
            "dPtsStatus" to ptsState, "dPtsCount" to pts.size,
            "dHardwareFirst" to (pts.firstOrNull{it.hardwareFrames!=null}?.hardwareFrames ?: -1L),
            "dHardwareLast" to (pts.lastOrNull{it.hardwareFrames!=null}?.hardwareFrames ?: -1L))
    }
    fun recover(context:Context):Map<String,Any> = recoverPointer(context,"latest_attempt_v1.txt",false)
    fun recoverD(context:Context):Map<String,Any> =
        recoverPointer(context,"latest_d_attempt_v1.txt",true)
    private fun recoverPointer(context:Context,pointerName:String,requireD:Boolean):Map<String,Any> {
        guard()
        val p=parent(context,false)
        val pointer=File(p,pointerName)
        if(!regular(pointer)) error("LAB_MULTI_MISSING_HOLD")
        check(pointer.length()==36L) { "LAB_MULTI_POINTER_HOLD" }
        val name=pointer.readText(Charsets.US_ASCII)
        check(uuid.matches(name)) { "LAB_MULTI_POINTER_HOLD" }
        val folder=File(p,name)
        check(folder.isDirectory && folder.absoluteFile==folder.canonicalFile) { "LAB_MULTI_POINTER_HOLD" }
        val r=snapshot(folder,UUID.fromString(name))
        check(pointer.readText(Charsets.US_ASCII)==name) { "LAB_MULTI_POINTER_HOLD" }
        if(requireD) check(r["dMode"]==true) { "LAB_D_RECOVER_MODE_HOLD" }
        return r
    }
    /** mode: 0 running, 1 interrupt, 2 explicit normal finish. */
    fun capture(context:Context,mode:AtomicInteger,captured:AtomicInteger,committed:AtomicInteger,
        hardwareD:Boolean=false):Map<String,Any> {
        guard()
        val p=parent(context,true)
        val id=UUID.randomUUID()
        val folder=File(p,id.toString())
        check(folder.mkdir()) { "LAB_MULTI_STORAGE_HOLD" }
        if(hardwareD) {
            // Separate D provenance: do not mistake a later A/B/C attempt for this session.
            val marker=File(folder,"d_pts_mode_v1.txt")
            check(marker.createNewFile()){"LAB_D_PTS_MODE_HOLD"}
            FileOutputStream(marker).use {
                it.write("v1\n".toByteArray(Charsets.US_ASCII));it.fd.sync()
            }
            val dtmp=File(p,"latest_d_$id.tmp")
            check(dtmp.createNewFile()){"LAB_D_POINTER_HOLD"}
            FileOutputStream(dtmp).use {
                it.write(id.toString().toByteArray(Charsets.US_ASCII));it.fd.sync()
            }
            Files.move(dtmp.toPath(),File(p,"latest_d_attempt_v1.txt").toPath(),
                StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        }
        val tmp=File(p,"latest_$id.tmp")
        check(tmp.createNewFile()) { "LAB_MULTI_POINTER_HOLD" }
        FileOutputStream(tmp).use { it.write(id.toString().toByteArray(Charsets.US_ASCII)); it.fd.sync() }
        // Only the latest-attempt pointer is replaced, never source audio.
        Files.move(tmp.toPath(),File(p,"latest_attempt_v1.txt").toPath(),StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING)
        check(folder.usableSpace>=8L*1024*1024) { "LAB_MULTI_STORAGE_HOLD" }
        val minimum=AudioRecord.getMinBufferSize(RATE,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT)
        check(minimum>0) { "LAB_MULTI_CONFIG_HOLD" }
        val recorder=AudioRecord(MediaRecorder.AudioSource.MIC,RATE,AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,maxOf(minimum,16384))
        val queue=ArrayBlockingQueue<ByteArray>(if(hardwareD)64 else 16)
        val done=AtomicBoolean(false)
        val normal=AtomicBoolean(false)
        val diskError=AtomicReference<Exception?>(null)
        val worker=Thread {
            try {
                LabMultiPartSink(folder,id,PART_BYTES,PART_COUNT,onCommit={committed.set(it)}).use { sink ->
                    while(!done.get()||queue.isNotEmpty()) {
                        val bytes=queue.poll(100,TimeUnit.MILLISECONDS)
                        if(bytes!=null) sink.accept(bytes)
                    }
                    sink.finish(normal.get())
                }
            } catch(e:Exception){diskError.set(e)}
        }
        var captureError:Exception?=null
        var workerStarted=false
        try {
            check(recorder.state==AudioRecord.STATE_INITIALIZED) { "LAB_MULTI_INIT_HOLD" }
            if(mode.get()!=0) return snapshot(folder,id)
            recorder.startRecording()
            check(recorder.recordingState==AudioRecord.RECORDSTATE_RECORDING) { "LAB_MULTI_START_HOLD" }
            worker.start();workerStarted=true
            val start=SystemClock.elapsedRealtimeNanos()
            val buffer=ByteArray(4096)
            var total=0
            var nextPtsNs=0L
            var ptsIndex=0
            while(total<MAX_BYTES && mode.get()==0) {
                diskError.get()?.let { throw it }
                check(SystemClock.elapsedRealtimeNanos()-start<45_000_000_000L) { "LAB_MULTI_TIMEOUT_HOLD" }
                val n=recorder.read(buffer,0,minOf(buffer.size,MAX_BYTES-total),AudioRecord.READ_NON_BLOCKING)
                check(n>=0 && n%2==0) { "LAB_MULTI_READ_HOLD" }
                if(n==0){Thread.sleep(10);continue}
                // No storage wait on the microphone thread; overflow is HOLD.
                check(queue.offer(buffer.copyOf(n))) { "LAB_MULTI_QUEUE_HOLD" }
                total+=n;captured.set(total/2)
                if(hardwareD) {
                    val observed=SystemClock.elapsedRealtimeNanos()
                    if(observed>=nextPtsNs && ptsIndex<16) {
                        // Read an actual Android AudioRecord hardware framePosition. Never
                        // synthesize it from total, wall time, or Part/sample indexes.
                        val stamp=AudioTimestamp()
                        val code=try {
                            recorder.getTimestamp(stamp,AudioTimestamp.TIMEBASE_MONOTONIC)
                        } catch(_:Exception) { AudioRecord.ERROR_INVALID_OPERATION }
                        val native=if(code==AudioRecord.SUCCESS && stamp.nanoTime>0 &&
                            stamp.framePosition>=0) stamp.framePosition else null
                        val nativeNs=if(native!=null)stamp.nanoTime else null
                        LabDPtsEvidence.publish(folder,++ptsIndex,
                            LabDPtsEvidence.Sample(total.toLong()/2,native,nativeNs,observed))
                        nextPtsNs=observed+4000000000L
                    }
                }
            }
            normal.set(mode.get()==2 || (total==MAX_BYTES && mode.get()==0))
        } catch(e:Exception) { captureError=e;normal.set(false) }
        finally {
            try { if(recorder.recordingState==AudioRecord.RECORDSTATE_RECORDING) recorder.stop() }
            catch(e:Exception){normal.set(false);if(captureError==null) captureError=e}
            finally {
                recorder.release()
                done.set(true)
                if(workerStarted) {
                    var interrupted=false
                    while(worker.isAlive) {
                        try {worker.join()} catch(_:InterruptedException){interrupted=true;normal.set(false)}
                    }
                    if(interrupted) Thread.currentThread().interrupt()
                }
            }
        }
        diskError.get()?.let { throw it }
        captureError?.let { throw it }
        return snapshot(folder,id)
    }
}
