package com.example.meeting_recorder.public_lab_v38.groq_stt_lab

import android.content.Context
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.os.SystemClock
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import org.json.JSONObject

/**
 * Foreground-only owner-consented LAB microphone source witness.
 * One AudioRecord stream yields two 3s mono PCM16 WAV Parts.
 * Offsets are physical frame counts in THIS Lab capture session only.
 * No remote calls, transcoding, persisted keys or cross-app provenance.
 */
internal object LabMicPartRecorder {
    private const val RATE = 16000
    private const val PART_FRAMES = 48000
    private const val PART_BYTES = PART_FRAMES * 2
    private const val PART_COUNT = 2

    private fun wavHeader(): ByteArray {
        val b = ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        b.put("RIFF".toByteArray(Charsets.US_ASCII))
        b.putInt(36 + PART_BYTES)
        b.put("WAVE".toByteArray(Charsets.US_ASCII))
        b.put("fmt ".toByteArray(Charsets.US_ASCII))
        b.putInt(16)
        b.putShort(1)
        b.putShort(1)
        b.putInt(RATE)
        b.putInt(RATE * 2)
        b.putShort(2)
        b.putShort(16)
        b.put("data".toByteArray(Charsets.US_ASCII))
        b.putInt(PART_BYTES)
        return b.array()
    }

    private fun sha256(file: File): String {
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(32768)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                hash.update(buffer, 0, count)
            }
        }
        return hash.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * Actual MIC capture runs only after MainActivity checks RECORD_AUDIO
     * permission and the owner explicitly taps a visible UI button.
     * No source file is deleted or silently overwritten, even on HOLD.
     */
    fun capture(context: Context): Map<String, Any> {
        val minimum = AudioRecord.getMinBufferSize(
            RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT)
        require(minimum > 0) { "LAB_MIC_CONFIG_HOLD" }
        val recorder = AudioRecord(MediaRecorder.AudioSource.MIC,
            RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT, maxOf(minimum, 8192))
        require(recorder.state == AudioRecord.STATE_INITIALIZED) {
            recorder.release()
            "LAB_MIC_INIT_HOLD"
        }
        val sessionId = UUID.randomUUID().toString()
        val parent = File(context.filesDir, "lab_mic_capture_v1")
        require(parent.isDirectory || parent.mkdirs()) {
            recorder.release()
            "LAB_MIC_STORAGE_HOLD"
        }
        val folder = File(parent, sessionId)
        require(folder.mkdir() && folder.canonicalFile.parentFile == parent.canonicalFile) {
            recorder.release()
            "LAB_MIC_STORAGE_HOLD"
        }
        val parts = ArrayList<Map<String, Any>>(PART_COUNT)
        val chunk = ByteArray(8192)
        var startedNs = 0L
        var endedNs = 0L
        try {
            recorder.startRecording()
            require(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "LAB_MIC_START_HOLD"
            }
            startedNs = SystemClock.elapsedRealtimeNanos()
            for (i in 0 until PART_COUNT) {
                val file = File(folder, "part_%02d.wav".format(i + 1))
                require(file.createNewFile()) { "LAB_MIC_PART_EXISTS_HOLD" }
                FileOutputStream(file, false).use { output ->
                    output.write(wavHeader())
                    var remaining = PART_BYTES
                    while (remaining > 0) {
                        require(!Thread.currentThread().isInterrupted) {
                            "LAB_MIC_INTERRUPTED_HOLD"
                        }
                        val count = recorder.read(chunk, 0, minOf(chunk.size, remaining),
                            AudioRecord.READ_BLOCKING)
                        require(count > 0 && count % 2 == 0) {
                            "LAB_MIC_READ_HOLD"
                        }
                        output.write(chunk, 0, count)
                        remaining -= count
                        require(SystemClock.elapsedRealtimeNanos() - startedNs <
                            45_000_000_000L) { "LAB_MIC_TIMEOUT_HOLD" }
                    }
                    output.fd.sync()
                }
                require(file.length() == PART_BYTES + 44L) {
                    "LAB_MIC_PART_SIZE_HOLD"
                }
                parts.add(mapOf(
                    "index" to (i + 1),
                    "path" to file.canonicalPath,
                    "bytes" to file.length(),
                    "sha256" to sha256(file),
                    "frameStart" to i.toLong() * PART_FRAMES,
                    "frameEnd" to (i + 1L) * PART_FRAMES))
            }
            endedNs = SystemClock.elapsedRealtimeNanos()
            require(endedNs - startedNs in 4_000_000_000L..45_000_000_000L) {
                "LAB_MIC_CLOCK_HOLD"
            }
            return mapOf(
                "sessionId" to sessionId,
                "sampleRate" to RATE,
                "startedMonoNs" to startedNs,
                "endedMonoNs" to endedNs,
                "parts" to parts)
        } finally {
            if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                recorder.stop()
            }
            recorder.release()
        }
    }

    /**
     * Separate interruption probe. First WAV is fully synced and SHA-bound
     * before tail capture starts. A tail is NEVER promoted to a WAV receipt.
     * Both files are kept; no automatic resume, deletion or remote request.
     */
    fun captureInterruptProbe(context: Context, cancelled: () -> Boolean): Map<String, Any> {
        val root = context.filesDir.canonicalFile
        val parent = File(root, "lab_mic_interrupt_v1")
        require((parent.isDirectory || parent.mkdir()) &&
            parent.canonicalFile == parent.absoluteFile) { "LAB_MIC_INTERRUPT_PATH_HOLD" }
        val id = UUID.randomUUID().toString()
        val folder = File(parent, id)
        require(folder.mkdir()) { "LAB_MIC_INTERRUPT_PATH_HOLD" }
        // Pointer identifies the newest attempted session, not an older success.
        writeExclusive(File(parent, "latest_$id.tmp"), id.toByteArray(Charsets.UTF_8))
        require(File(parent, "latest_$id.tmp").renameTo(File(parent, "latest_attempt_v1.txt"))) {
            "LAB_MIC_INTERRUPT_POINTER_HOLD"
        }
        val minimum = AudioRecord.getMinBufferSize(RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        require(minimum > 0) { "LAB_MIC_CONFIG_HOLD" }
        val recorder = AudioRecord(MediaRecorder.AudioSource.MIC, RATE,
            AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT,
            maxOf(minimum, 8192))
        val chunk = ByteArray(8192)
        var committed = 0
        val started = SystemClock.elapsedRealtimeNanos()
        fun shouldStop(): Boolean = cancelled() || Thread.currentThread().isInterrupted
        fun stopResult(): Map<String, Any> = mapOf(
            "status" to "stopped", "committedParts" to committed)
        fun writeFrames(output: FileOutputStream, bytes: Int): Boolean {
            var remaining = bytes
            while (remaining > 0) {
                if (shouldStop()) return false
                require(SystemClock.elapsedRealtimeNanos() - started < 45_000_000_000L) {
                    "LAB_MIC_TIMEOUT_HOLD"
                }
                val count = recorder.read(chunk, 0, minOf(chunk.size, remaining),
                    AudioRecord.READ_BLOCKING)
                if (shouldStop()) return false
                require(count > 0 && count % 2 == 0) { "LAB_MIC_READ_HOLD" }
                output.write(chunk, 0, count)
                remaining -= count
            }
            return true
        }
        try {
            require(recorder.state == AudioRecord.STATE_INITIALIZED) { "LAB_MIC_INIT_HOLD" }
            if (shouldStop()) return stopResult()
            recorder.startRecording()
            require(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "LAB_MIC_START_HOLD"
            }
            val first = File(folder, "part_01.wav")
            require(first.createNewFile()) { "LAB_MIC_PART_EXISTS_HOLD" }
            FileOutputStream(first, false).use { output ->
                output.write(wavHeader())
                val full = writeFrames(output, PART_BYTES)
                output.fd.sync()
                if (!full) return stopResult()
            }
            require(first.length() == PART_BYTES + 44L) { "LAB_MIC_PART_SIZE_HOLD" }
            val receipt = JSONObject()
                .put("schema", 1).put("sessionId", id).put("sampleRate", RATE)
                .put("index", 1).put("file", "part_01.wav")
                .put("bytes", first.length()).put("sha256", sha256(first))
                .put("frameStart", 0).put("frameEnd", PART_FRAMES)
            // A torn temporary receipt cannot be mistaken for a committed Part.
            val temp = File(folder, "part_01_commit.tmp")
            writeExclusive(temp, receipt.toString().toByteArray(Charsets.UTF_8))
            require(temp.renameTo(File(folder, "part_01_commit_v1.json"))) {
                "LAB_MIC_INTERRUPT_COMMIT_HOLD"
            }
            committed = 1
            if (shouldStop()) return stopResult()
            // Up to 15s tail; it is intentionally NOT a WAV or a committed Part.
            val tail = File(folder, "part_02_inflight.pcm")
            require(tail.createNewFile()) { "LAB_MIC_PART_EXISTS_HOLD" }
            FileOutputStream(tail, false).use { output ->
                val full = writeFrames(output, RATE * 2 * 15)
                output.fd.sync()
                if (!full) return stopResult()
            }
            if (shouldStop()) return stopResult()
            writeExclusive(File(folder, "finished_v1.txt"), "completed".toByteArray(Charsets.UTF_8))
            return mapOf("status" to "completed", "committedParts" to committed)
        } finally {
            try {
                if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) recorder.stop()
            } finally {
                recorder.release()
            }
        }
    }

    private fun writeExclusive(file: File, bytes: ByteArray) {
        require(file.createNewFile()) { "LAB_MIC_INTERRUPT_EXISTS_HOLD" }
        FileOutputStream(file, false).use { output ->
            output.write(bytes)
            output.fd.sync()
        }
    }
}
