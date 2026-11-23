package com.example.meeting_recorder.public_lab_v39.groq_stt_lab

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.nio.file.FileAlreadyExistsException
import java.security.MessageDigest
import java.util.UUID

/** Local committed-prefix journal, independent of Activity/AudioRecord.
 * Single writer, private per-session directory, no audio rewrite or tail promotion.
 * Requires java.nio.file support (Android API 26+ before use).
 * The sample ledger is not a hardware PTS or power-loss attestation.
 */
internal class LabMultiPartProof(private val folder: File, private val session: UUID,
    private val receiptWriter: ((File, ByteArray) -> Unit)? = null) {
    data class Receipt(val index: Int, val start: Long, val end: Long, val bytes: Long, val sha: String)
    data class Recovery(val receipts: List<Receipt>, val finished: Boolean)
    private val maxParts = 128
    private fun requireSafe(ok: Boolean) = check(ok) { "LAB_MULTI_PART_PROOF_HOLD" }
    // No raw IOException messages (which may contain sandbox paths) leave the native layer.
    private fun <T> atPhase(code: String, action: () -> T): T {
        return try { action() } catch (error: Exception) {
            if (error.message?.matches(Regex("^LAB_[A-Z0-9_]{2,55}_HOLD$")) == true) throw error
            throw IllegalStateException(code, error)
        }
    }
    private fun root(): File {
        requireSafe(folder.name == session.toString() && folder.absoluteFile == folder.canonicalFile && folder.isDirectory)
        return folder
    }
    private fun file(name: String): File = File(root(), name)
    private fun stem(index: Int) = "part_%06d".format(java.util.Locale.ROOT, index)
    private fun regular(f: File): Boolean = Files.isRegularFile(f.toPath(), LinkOption.NOFOLLOW_LINKS) && f.absoluteFile == f.canonicalFile
    private fun present(f: File) = Files.exists(f.toPath(), LinkOption.NOFOLLOW_LINKS)
    private fun inspect(index: Int, start: Long): Receipt {
        val wav = file(stem(index) + ".wav")
        requireSafe(regular(wav))
        val size = wav.length()
        requireSafe(size > 44 && size <= 115200044L && (size - 44) % 2 == 0L)
        val md = MessageDigest.getInstance("SHA-256")
        wav.inputStream().buffered().use { input ->
            val header = ByteArray(44)
            java.io.DataInputStream(input).readFully(header)
            val b = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
            fun tag(at: Int, value: String) = header.copyOfRange(at, at + 4).contentEquals(value.toByteArray(Charsets.US_ASCII))
            requireSafe(tag(0,"RIFF") && tag(8,"WAVE") && tag(12,"fmt ") && tag(36,"data") &&
                b.getInt(4).toLong() == size - 8 && b.getInt(16) == 16 && b.getShort(20).toInt() == 1 &&
                b.getShort(22).toInt() == 1 && b.getInt(24) == 16000 && b.getInt(28) == 32000 &&
                b.getShort(32).toInt() == 2 && b.getShort(34).toInt() == 16 && b.getInt(40).toLong() == size - 44)
            md.update(header)
            val buf = ByteArray(32768)
            var total = 44L
            while (true) { val n = input.read(buf); if (n < 0) break; md.update(buf, 0, n); total += n }
            requireSafe(total == size && wav.length() == size)
        }
        return Receipt(index, start, Math.addExact(start, (size - 44) / 2), size,
            md.digest().joinToString("") { "%02x".format(it) })
    }
    private fun encode(r: Receipt) = "v1\t$session\t${r.index}\t${r.start}\t${r.end}\t${r.bytes}\t${r.sha}\n"
    /** Read only. Ignore uncommitted WAV/tail; reject gaps and malformed committed receipts. */
    private fun scan(): List<Receipt> {
        val entries = root().listFiles() ?: error("LAB_MULTI_PART_PROOF_HOLD")
        val commits = entries.filter { it.name.endsWith(".commit") }.sortedBy { it.name }
        requireSafe(commits.size <= maxParts)
        val out = mutableListOf<Receipt>()
        var start = 0L
        for ((offset, commit) in commits.withIndex()) {
            val index = offset + 1
            requireSafe(commit.name == stem(index) + ".commit" && regular(commit) && commit.length() in 1..512)
            val receipt = inspect(index, start)
            requireSafe(commit.readText(Charsets.US_ASCII) == encode(receipt))
            out.add(receipt); start = receipt.end
        }
        return out.toList()
    }
    private fun terminal() = file("finished_v1.txt")
    private fun terminalProof(parts: List<Receipt>): String {
        requireSafe(parts.isNotEmpty())
        val last = parts.last()
        return "v1\t$session\t${last.index}\t${last.end}\t${last.sha}\n"
    }
    /** Missing terminal means only a verified prefix, never proof of full recording. */
    fun recoverSnapshot(): Recovery {
        val parts = scan().also { requireSafe(it.isNotEmpty()) }
        val marker = terminal()
        val done = present(marker)
        if (done) requireSafe(regular(marker) && marker.length() in 1..512 &&
            marker.readText(Charsets.US_ASCII) == terminalProof(parts))
        return Recovery(parts, done)
    }
    fun recover(): List<Receipt> = recoverSnapshot().receipts

    /** Exclusive-create, fsync and exact readback; never overwrite an existing receipt.
     * CREATE_NEW is atomic for name creation, NOT atomic publication of its content.
     * A crash during write leaves a partial receipt; scan rejects it fail-closed.
     * Original PCM/WAV is NEVER modified or deleted by journal publication.
     */
    private fun publish(dest: File, text: String) {
        requireSafe(!present(dest))
        val expected = text.toByteArray(Charsets.US_ASCII)
        try {
            val injected = receiptWriter
            if (injected != null) {
                injected(dest, expected)
            } else {
                FileChannel.open(dest.toPath(),
                    StandardOpenOption.CREATE_NEW,
                    StandardOpenOption.WRITE).use { channel ->
                    val source = ByteBuffer.wrap(expected)
                    while (source.hasRemaining()) {
                        requireSafe(channel.write(source) > 0)
                    }
                    channel.force(true)
                }
            }
        } catch (error: FileAlreadyExistsException) {
            throw IllegalStateException("LAB_MULTI_RECEIPT_EXISTS_HOLD", error)
        } catch (error: UnsupportedOperationException) {
            throw IllegalStateException("LAB_MULTI_RECEIPT_UNSUPPORTED_HOLD", error)
        } catch (error: java.io.IOException) {
            throw IllegalStateException("LAB_MULTI_RECEIPT_WRITE_HOLD", error)
        }
        atPhase("LAB_MULTI_RECEIPT_READBACK_HOLD") {
            requireSafe(regular(dest) && dest.length() == expected.size.toLong())
            requireSafe(dest.readBytes().contentEquals(expected))
        }
    }

    /** Only the recorder's explicit normal finalization may publish a terminal marker. */
    @Synchronized fun finish(expectedParts: Int): Recovery {
        val parts = scan()
        requireSafe(parts.isNotEmpty() && parts.size == expectedParts)
        publish(terminal(), terminalProof(parts))
        return recoverSnapshot().also { requireSafe(it.finished && it.receipts == parts) }
    }

    /** Publish only after caller has finished/synced an immutable WAV.
     * Call from a serialized journal worker, not the microphone read loop.
     * Exclusive atomic publication required; no retry with weaker semantics.
     */
    @Synchronized fun commit(index: Int): Receipt {
        requireSafe(!present(terminal()))
        val prior = scan()
        requireSafe(index == prior.size + 1 && index <= maxParts)
        val receipt = atPhase("LAB_MULTI_WAV_INSPECT_HOLD") { inspect(index, prior.lastOrNull()?.end ?: 0L) }
        val dest = file(stem(index) + ".commit")
        publish(dest, encode(receipt))
        atPhase("LAB_MULTI_RECEIPT_READBACK_HOLD") { requireSafe(recover().lastOrNull() == receipt) }
        return receipt
    }
}


/** Serialized disk worker. Raw PCM is kept; only fully verified WAV receipts
 * are committed. A process death leaves the uncommitted tail isolated.
 */
internal class LabMultiPartSink(
    private val folder: File, session: UUID,
    private val partBytes: Int, private val partLimit: Int,
    private val spaceOk: () -> Boolean = { folder.usableSpace >= 8L * 1024 * 1024 },
    private val onCommit: (Int) -> Unit = {}
) : java.io.Closeable {
    private val proof = LabMultiPartProof(folder, session)
    private var index = 1
    private var written = 0
    private var raw: File? = null
    private var output: FileOutputStream? = null
    private var ended = false
    init { require(partBytes in 2..115200000 && partBytes % 2 == 0 && partLimit in 1..128) }
    private fun stem() = "part_%06d".format(java.util.Locale.ROOT,index)
    private fun ensureSpace() = check(spaceOk()) { "LAB_MULTI_STORAGE_HOLD" }
    private fun <T> atPhase(code:String, action:()->T):T {
        return try { action() } catch(error:Exception) {
            if(error.message?.matches(Regex("^LAB_[A-Z0-9_]{2,55}_HOLD$"))==true) throw error
            throw IllegalStateException(code,error)
        }
    }
    private fun open() {
        check(!ended && index <= partLimit)
        ensureSpace()
        val f = File(folder,stem()+"_inflight.pcm")
        check(f.createNewFile()) { "LAB_MULTI_EXISTS_HOLD" }
        raw=f; output=FileOutputStream(f)
    }
    private fun seal() {
        check(written>0 && written%2==0)
        val f=requireNotNull(raw)
        atPhase("LAB_MULTI_RAW_FSYNC_HOLD") {
            requireNotNull(output).let { it.fd.sync(); it.close() }
        }
        output=null
        check(f.length()==written.toLong()) { "LAB_MULTI_SIZE_HOLD" }
        ensureSpace()
        val wav=File(folder,stem()+".wav")
        atPhase("LAB_MULTI_WAV_CREATE_HOLD") { check(wav.createNewFile()) { "LAB_MULTI_EXISTS_HOLD" } }
        val b=ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(s:String) { b.put(s.toByteArray(Charsets.US_ASCII)) }
        tag("RIFF"); b.putInt(36+written); tag("WAVE"); tag("fmt "); b.putInt(16)
        b.putShort(1); b.putShort(1); b.putInt(16000); b.putInt(32000)
        b.putShort(2); b.putShort(16); tag("data"); b.putInt(written)
        atPhase("LAB_MULTI_WAV_FSYNC_HOLD") {
            FileOutputStream(wav).use { out ->
                out.write(b.array())
                f.inputStream().use { input ->
                    check(input.copyTo(out)==written.toLong()) { "LAB_MULTI_SIZE_HOLD" }
                }
                out.fd.sync()
            }
        }
        val receipt=atPhase("LAB_MULTI_RECEIPT_COMMIT_HOLD") { proof.commit(index) }
        check(receipt.bytes==written.toLong()+44L)
        onCommit(index)
        index++;written=0;raw=null
    }
    fun accept(bytes:ByteArray) {
        check(!ended && bytes.isNotEmpty() && bytes.size%2==0)
        var offset=0
        while(offset<bytes.size) {
            if(output==null) open()
            ensureSpace()
            val take=minOf(partBytes-written,bytes.size-offset)
            requireNotNull(output).write(bytes,offset,take)
            written+=take;offset+=take
            if(written==partBytes) seal()
        }
    }
    /** Normal stop seals a nonempty final partial Part; interrupt does not. */
    fun finish(normal:Boolean) {
        check(!ended)
        if(normal && written>0) seal()
        close()
        if(normal) {
            check(index>1) { "LAB_MULTI_UNCOMMITTED_HOLD" }
            proof.finish(index-1)
        }
    }
    override fun close() {
        ended=true
        val out=output
        output=null
        if(out!=null) { try { out.fd.sync() } finally { out.close() } }
    }
}
