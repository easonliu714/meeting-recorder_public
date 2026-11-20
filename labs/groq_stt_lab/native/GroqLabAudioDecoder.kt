package com.example.meeting_recorder.public_lab_v27.groq_stt_lab

import android.content.Context
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.os.StatFs
import java.io.File
import java.io.FileInputStream
import java.io.RandomAccessFile
import java.nio.ByteOrder
import java.security.MessageDigest

/**
 * P0-C: on-device MP3/AAC -> physical mono PCM16 WAV for ONE bounded Part-local
 * window. No HTTP, provider consent, Note or Journal mutation is performed.
 * A separate caller must attest and journal the wire before any upload.
 *
 * MediaCodec's decoded PTS (not encoded byte offsets/bitrate) defines the clock.
 * The 16 kHz output grid uses deterministic linear interpolation. Fail closed
 * for unknown duration, changed source, timestamp discontinuity, corrupt EOF,
 * unsupported PCM formats or a wire at/over the strict decimal byte ceiling.
 */
internal class LabPcmWindowEvidence(val safeMetrics: Map<String, Long>) :
    IllegalStateException("LAB_AUDIO_INCOMPLETE_PCM_WINDOW")

// The early leading-PTS guard emits only integer diagnostics, never source data.
internal class LabLeadingPtsEvidence(val safeMetrics: Map<String, Long>) :
    IllegalStateException("LAB_AUDIO_LEADING_PTS_HOLD")

internal object GroqLabAudioDecoder {
    private const val TARGET_RATE = 16000
    private const val WIRE_CEILING = 22_500_000L
    private const val MAX_WINDOW_US = 702_000_000L
    private const val MAX_GAP_US = 150_000L
    // Only one AAC-LC (1024-sample) source-rate priming frame plus 2ms
    // rounding may be rebased at the first wire; no silent PCM is created.
    // MP3 continues using the frozen 50ms guard.
    private fun firstWireLeadingLimitUs(mime: String, inputRate: Int): Long =
        if (mime == "audio/mp4a-latm") {
            minOf(130_000L, (1_024_000_000L + inputRate - 1L) / inputRate + 2_000L)
        } else 50_000L
    private const val MAX_INPUT_BYTES = 2 * 1024 * 1024
    // A short MP3 seek may not return the full decoder tail on all devices.
    // A replay from file offset 0 is allowed ONCE, ONLY for a bounded 15m
    // nonfirst wire with an observed short tail, and still uses full PCM gates.
    private const val MAX_REPLAY_END_MS = 15L * 60L * 1000L
    private const val MAX_REPLAY_MISSING_FRAMES = 32_000L
    private const val MAX_REPLAY_TAIL_GAP_US = 2_000_000L

    private fun eligibleForOriginReplay(
        metrics: Map<String, Long>, startMs: Long, endMs: Long
    ): Boolean {
        if (startMs <= 0L || endMs > MAX_REPLAY_END_MS || endMs <= startMs) return false
        val expected = metrics["expected_frames"] ?: return false
        val decoded = metrics["decoded_frames"] ?: return false
        val first = metrics["first_pts_us"] ?: return false
        val last = metrics["last_pts_us"] ?: return false
        val startUs = startMs * 1000L
        val endUs = endMs * 1000L
        val missing = expected - decoded
        return expected > 0L && decoded > 0L &&
            missing in 321L..MAX_REPLAY_MISSING_FRAMES &&
            first >= 0L && first <= startUs &&
            last >= endUs - MAX_REPLAY_TAIL_GAP_US && last < endUs
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { stream ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val count = stream.read(buffer)
                if (count < 0) break
                if (count > 0) digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 255) }
    }

    private fun writeLe16(file: RandomAccessFile, value: Int) {
        file.write(value and 255)
        file.write((value ushr 8) and 255)
    }

    private fun writeLe32(file: RandomAccessFile, value: Long) {
        require(value in 0L..0xffffffffL) { "WAV_SIZE_OVERFLOW" }
        for (shift in 0..3) file.write(((value ushr (8 * shift)) and 255L).toInt())
    }

    private fun finishWav(file: RandomAccessFile, frames: Long) {
        val pcmBytes = frames * 2L
        require(pcmBytes + 44L < WIRE_CEILING) { "LAB_AUDIO_PCM_WIRE_TOO_LARGE" }
        file.seek(0L)
        file.writeBytes("RIFF")
        writeLe32(file, pcmBytes + 36L)
        file.writeBytes("WAVEfmt ")
        writeLe32(file, 16L)
        writeLe16(file, 1)
        writeLe16(file, 1)
        writeLe32(file, TARGET_RATE.toLong())
        writeLe32(file, TARGET_RATE * 2L)
        writeLe16(file, 2)
        writeLe16(file, 16)
        file.writeBytes("data")
        writeLe32(file, pcmBytes)
    }

    /** Extract the real codec and timeline from bytes, never filename. */
    fun inspectSource(sourcePath: String): Map<String, Any> {
        val source = File(sourcePath).canonicalFile
        require(source.isFile && source.canRead() && source.length() > 0L) {
            "LAB_AUDIO_SOURCE_UNREADABLE"
        }
        val extractor = MediaExtractor()
        try {
            extractor.setDataSource(source.path)
            var audioTrack = -1
            var selected: MediaFormat? = null
            for (index in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(index)
                if ((candidate.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                    require(audioTrack == -1) { "LAB_AUDIO_MULTIPLE_AUDIO_TRACKS" }
                    audioTrack = index
                    selected = candidate
                }
            }
            val format = requireNotNull(selected) { "LAB_AUDIO_NO_AUDIO_TRACK" }
            val mime = format.getString(MediaFormat.KEY_MIME)
            require(mime == "audio/mpeg" || mime == "audio/mp4a-latm") {
                "LAB_AUDIO_UNSUPPORTED_CODEC"
            }
            require(format.containsKey(MediaFormat.KEY_DURATION) &&
                    format.containsKey(MediaFormat.KEY_SAMPLE_RATE) &&
                    format.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                "LAB_AUDIO_METADATA_MISSING"
            }
            val duration = format.getLong(MediaFormat.KEY_DURATION)
            val rate = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val channels = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            require(duration in 10_000L..172_800_000_000L &&
                    rate in 8000..48000 && channels in 1..2) {
                "LAB_AUDIO_FORMAT_OR_DURATION_HOLD"
            }
            return mapOf(
                "mime" to requireNotNull(mime),
                "durationUs" to duration,
                "sampleRate" to rate,
                "channels" to channels,
                "sourceBytes" to source.length()
            )
        } finally {
            extractor.release()
        }
    }

    fun decodeWindow(
        context: Context, sourcePath: String, startMs: Long, endMs: Long
    ): Map<String, Any> {
        try {
            return decodeWindowAttempt(context, sourcePath, startMs, endMs,
                fromOrigin = false)
        } catch (first: LabPcmWindowEvidence) {
            if (!eligibleForOriginReplay(first.safeMetrics, startMs, endMs)) throw first
            // MIME is sniffed by MediaExtractor, never extension or filename.
            val actualMime = try {
                inspectSource(sourcePath)["mime"]
            } catch (_: Exception) {
                null
            }
            if (actualMime != "audio/mpeg") throw first
            return try {
                // A single read-only local replay from origin. Never Groq retry.
                decodeWindowAttempt(context, sourcePath, startMs, endMs,
                    fromOrigin = true)
            } catch (again: LabPcmWindowEvidence) {
                // Report only bounded numeric evidence, not source paths or PCM.
                throw LabPcmWindowEvidence(again.safeMetrics +
                    ("mp3_origin_replay_attempted" to 1L))
            }
        }
    }

    private fun decodeWindowAttempt(
        context: Context, sourcePath: String, startMs: Long, endMs: Long,
        fromOrigin: Boolean
    ): Map<String, Any> {
        require(startMs >= 0L && endMs > startMs && endMs <= Long.MAX_VALUE / 1000L) {
            "LAB_AUDIO_INVALID_WINDOW"
        }
        val startUs = startMs * 1000L
        val endUs = endMs * 1000L
        require(endUs - startUs in 10_000L..MAX_WINDOW_US) { "LAB_AUDIO_WINDOW_OUT_OF_RANGE" }
        val source = File(sourcePath).canonicalFile
        require(source.isFile && source.canRead() && source.length() > 0L) {
            "LAB_AUDIO_SOURCE_INVALID"
        }
        val originalBytes = source.length()
        val originalModified = source.lastModified()
        val originalSha = sha256(source)
        // P0-C: validate the cache directory BEFORE creating a physical WAV.
        // A linked groq_lab_native_pcm directory must not redirect native writes
        // outside app-owned cache; Dart's post-decode check is not sufficient.
        val cacheRoot = context.cacheDir.canonicalFile
        require(cacheRoot.isDirectory && cacheRoot.canWrite()) {
            "LAB_AUDIO_CACHE_UNAVAILABLE"
        }
        require(StatFs(cacheRoot.path).availableBytes >= 50_000_000L) {
            "LAB_AUDIO_INSUFFICIENT_TEMP_STORAGE"
        }
        val owned = File(cacheRoot, "groq_lab_native_pcm")
        require(owned.isDirectory || owned.mkdir()) { "LAB_AUDIO_CACHE_UNAVAILABLE" }
        val ownedCanonical = owned.canonicalFile
        require(ownedCanonical.path == owned.absolutePath &&
                ownedCanonical.parentFile?.canonicalPath == cacheRoot.path &&
                ownedCanonical.isDirectory && ownedCanonical.canWrite() &&
                !source.path.startsWith(ownedCanonical.path + File.separator)) {
            "LAB_AUDIO_CACHE_SCOPE_HOLD"
        }

        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var output: File? = null
        var completed = false
        try {
            extractor.setDataSource(source.path)
            var track = -1
            var format: MediaFormat? = null
            for (i in 0 until extractor.trackCount) {
                val candidate = extractor.getTrackFormat(i)
                if ((candidate.getString(MediaFormat.KEY_MIME) ?: "").startsWith("audio/")) {
                    require(track == -1) { "LAB_AUDIO_MULTIPLE_AUDIO_TRACKS" }
                    track = i
                    format = candidate
                }
            }
            require(track >= 0 && format != null) { "LAB_AUDIO_NO_AUDIO_TRACK" }
            val input = requireNotNull(format)
            val mime = requireNotNull(input.getString(MediaFormat.KEY_MIME))
            require(mime == "audio/mpeg" || mime == "audio/mp4a-latm") {
                "LAB_AUDIO_REAL_CODEC_REQUIRED"
            }
            require(input.containsKey(MediaFormat.KEY_DURATION)) { "LAB_AUDIO_DURATION_UNKNOWN" }
            val durationUs = input.getLong(MediaFormat.KEY_DURATION)
            require(durationUs > 0L && endUs <= durationUs) { "LAB_AUDIO_WINDOW_PAST_EOF" }
            require(input.containsKey(MediaFormat.KEY_SAMPLE_RATE) &&
                    input.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                "LAB_AUDIO_FORMAT_UNKNOWN"
            }
            val inputRate = input.getInteger(MediaFormat.KEY_SAMPLE_RATE)
            val inputChannels = input.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
            require(inputRate in 8000..48000 && inputChannels in 1..2) {
                "LAB_AUDIO_UNSUPPORTED_CHANNELS_OR_RATE"
            }
            val leadingPtsLimitUs = firstWireLeadingLimitUs(mime, inputRate)
            extractor.selectTrack(track)
            extractor.seekTo(
                if (fromOrigin) 0L else maxOf(0L, startUs - 1_000_000L),
                MediaExtractor.SEEK_TO_PREVIOUS_SYNC)
            val active = MediaCodec.createDecoderByType(mime)
            codec = active
            active.configure(input, null, null, 0)
            active.start()

            val staged = File.createTempFile("groq_lab_pcm_", ".wav", ownedCanonical)
            output = staged
            val file = RandomAccessFile(staged, "rw")
            var frames = 0L
            var firstDecodedUs = -1L
            var lastDecodedUs = -1L
            var prevUs = -1L
            var prevMono = 0
            var inputEos = false
            var outputEos = false
            var rate = inputRate
            var channels = inputChannels
            var iterations = 0
            var lastInputPtsUs = -1L
            var inputPacketsQueued = 0L
            try {
                file.setLength(0L)
                file.write(ByteArray(44))
                val info = MediaCodec.BufferInfo()
                while (!outputEos) {
                    require(!Thread.currentThread().isInterrupted) { "LAB_AUDIO_CANCELLED" }
                    iterations++
                    require(iterations <= 2_000_000) { "LAB_AUDIO_DECODE_TIMEOUT" }
                    if (!inputEos) {
                        val index = active.dequeueInputBuffer(10_000L)
                        if (index >= 0) {
                            val buffer = requireNotNull(active.getInputBuffer(index))
                            buffer.clear()
                            val pts = extractor.sampleTime
                            if (pts < 0L || pts > endUs + 100_000L) {
                                active.queueInputBuffer(index, 0, 0, maxOf(0L, endUs),
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputEos = true
                            } else {
                                require(extractor.sampleTrackIndex == track) {
                                    "LAB_AUDIO_WRONG_TRACK"
                                }
                                val count = extractor.readSampleData(buffer, 0)
                                require(count in 1..MAX_INPUT_BYTES && count <= buffer.capacity()) {
                                    "LAB_AUDIO_INVALID_PACKET"
                                }
                                active.queueInputBuffer(index, 0, count, pts, 0)
                                lastInputPtsUs = pts
                                inputPacketsQueued++
                                extractor.advance()
                            }
                        }
                    }
                    when (val index = active.dequeueOutputBuffer(info, 10_000L)) {
                        MediaCodec.INFO_TRY_AGAIN_LATER -> Unit
                        MediaCodec.INFO_OUTPUT_BUFFERS_CHANGED -> Unit
                        MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val outFormat = active.outputFormat
                            require(outFormat.containsKey(MediaFormat.KEY_SAMPLE_RATE) &&
                                    outFormat.containsKey(MediaFormat.KEY_CHANNEL_COUNT)) {
                                "LAB_AUDIO_OUTPUT_FORMAT_UNKNOWN"
                            }
                            rate = outFormat.getInteger(MediaFormat.KEY_SAMPLE_RATE)
                            channels = outFormat.getInteger(MediaFormat.KEY_CHANNEL_COUNT)
                            require(rate == inputRate && channels == inputChannels) {
                                "LAB_AUDIO_OUTPUT_FORMAT_DRIFT"
                            }
                            if (outFormat.containsKey("pcm-encoding")) {
                                require(outFormat.getInteger("pcm-encoding") ==
                                    AudioFormat.ENCODING_PCM_16BIT) {
                                    "LAB_AUDIO_NON_PCM16_OUTPUT"
                                }
                            }
                        }
                        else -> if (index >= 0) {
                            if (info.size > 0) {
                                require(info.presentationTimeUs >= 0L) { "LAB_AUDIO_NEGATIVE_PTS" }
                                val data = requireNotNull(active.getOutputBuffer(index))
                                    .duplicate().order(ByteOrder.LITTLE_ENDIAN)
                                require(info.offset >= 0 && info.size >= 0 &&
                                        info.offset + info.size <= data.capacity() &&
                                        info.size % (channels * 2) == 0) {
                                    "LAB_AUDIO_BAD_PCM_FRAME"
                                }
                                data.position(info.offset)
                                data.limit(info.offset + info.size)
                                val count = info.size / (channels * 2)
                                for (i in 0 until count) {
                                    val left = data.short.toInt()
                                    val mono = if (channels == 2)
                                        (left + data.short.toInt()) / 2 else left
                                    val rawPts = info.presentationTimeUs +
                                        i.toLong() * 1_000_000L / rate
                                    require(lastDecodedUs < 0L || rawPts > lastDecodedUs) {
                                        "LAB_AUDIO_NON_MONOTONIC_PCM_PTS"
                                    }
                                    if (firstDecodedUs < 0L) firstDecodedUs = rawPts
                                    // Only the first wire may normalize one source-rate
                                    // codec priming frame; never fabricate silent PCM.
                                    val leadingUs = if (startUs == 0L) firstDecodedUs else 0L
                                    if (leadingUs !in 0L..leadingPtsLimitUs) {
                                        throw LabLeadingPtsEvidence(mapOf(
                                            "first_pts_us" to firstDecodedUs,
                                            "leading_pts_limit_us" to leadingPtsLimitUs,
                                            "source_sample_rate_hz" to inputRate.toLong(),
                                            "window_start_us" to startUs,
                                            "window_end_us" to endUs,
                                            "last_input_pts_us" to lastInputPtsUs,
                                            "input_packets_queued" to inputPacketsQueued
                                        ))
                                    }
                                    val pts = rawPts - leadingUs
                                    if (prevUs >= 0L && pts - prevUs > MAX_GAP_US) {
                                        throw IllegalStateException("LAB_AUDIO_PCM_GAP")
                                    }
                                    if (prevUs >= 0L) {
                                        while (true) {
                                            val target = startUs +
                                                frames * 1_000_000L / TARGET_RATE
                                            if (target >= endUs || target > pts) break
                                            if (target < prevUs) break
                                            val interpolated = if (pts == prevUs) mono else
                                                prevMono + ((mono - prevMono).toLong() *
                                                    (target - prevUs) / (pts - prevUs)).toInt()
                                            writeLe16(file, interpolated.coerceIn(-32768, 32767))
                                            frames++
                                            require(44L + frames * 2L < WIRE_CEILING) {
                                                "LAB_AUDIO_PCM_WIRE_TOO_LARGE"
                                            }
                                        }
                                    }
                                    prevUs = pts
                                    prevMono = mono
                                    lastDecodedUs = rawPts
                                }
                            }
                            outputEos = (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0
                            active.releaseOutputBuffer(index, false)
                        }
                    }
                }
                val expected = (endUs - startUs) * TARGET_RATE / 1_000_000L
                // Retain the strict no-loss gate. Report only bounded
                // timing/frame counters so real MP3/AAC encoder padding can
                // be distinguished from missing decoded audio without guessing
                // a fix, padding silence, or emitting an incomplete Chunk.
                val leadingUs = if (startUs == 0L) maxOf(0L, firstDecodedUs) else 0L
                val leadingFrames = leadingUs * TARGET_RATE / 1_000_000L
                // Compensation is only clock evidence, never PCM bytes.
                if (!(frames > 0L && frames + leadingFrames >= expected - 320L &&
                        frames <= expected &&
                        firstDecodedUs <= startUs +
                            (if (startUs == 0L) leadingPtsLimitUs else 0L) &&
                        lastDecodedUs >= endUs - 25_000L)) {
                    throw LabPcmWindowEvidence(mapOf(
                        "expected_frames" to expected,
                        "decoded_frames" to frames,
                        "first_pts_us" to firstDecodedUs,
                        "last_pts_us" to lastDecodedUs,
                        "window_start_us" to startUs,
                        "window_end_us" to endUs,
                        "source_duration_us" to durationUs,
                        "last_input_pts_us" to lastInputPtsUs,
                        "input_packets_queued" to inputPacketsQueued,
                        "input_eos_queued" to if (inputEos) 1L else 0L,
                        "output_eos_seen" to if (outputEos) 1L else 0L
                    ))
                }
                finishWav(file, frames)
            } finally {
                file.close()
            }
            val bytes = staged.length()
            require(bytes == 44L + frames * 2L && bytes < WIRE_CEILING) {
                "LAB_AUDIO_WAV_SIZE_MISMATCH"
            }
            require(source.isFile && source.length() == originalBytes &&
                    source.lastModified() == originalModified &&
                    sha256(source) == originalSha) { "LAB_AUDIO_SOURCE_CHANGED" }
            val wireSha = sha256(staged)
            completed = true
            return mapOf(
                "outputPath" to staged.absolutePath,
                "bytes" to bytes,
                "mime" to "audio/wav",
                "codec" to "audio/pcm",
                "sampleRate" to TARGET_RATE,
                "channels" to 1,
                "bitsPerSample" to 16,
                "outputFrames" to frames,
                "inputSampleRateHz" to inputRate,
                "firstDecodedPtsUs" to firstDecodedUs,
                "lastDecodedPtsUs" to lastDecodedUs,
                "leadingPtsCompensationUs" to if (startUs == 0L) firstDecodedUs else 0L,
                "requestedStartUs" to startUs,
                "requestedEndUs" to endUs,
                "sourceDurationUs" to durationUs,
                "sourceBytes" to originalBytes,
                "sourceSha256" to originalSha,
                "wireSha256" to wireSha,
                "decoderVerified" to true,
                "acousticTimingVerified" to false,
                "ownerPlaybackVerified" to false,
                "providerUploadAuthorized" to false,
                "mp3OriginReplay" to fromOrigin
            )
        } finally {
            try { codec?.stop() } catch (_: Exception) { }
            try { codec?.release() } catch (_: Exception) { }
            extractor.release()
            if (!completed) output?.delete()
        }
    }
}
