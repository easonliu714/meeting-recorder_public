package com.example.meeting_recorder.public_lab_v32.groq_stt_lab

import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.LinkOption
import java.security.MessageDigest
import java.util.UUID

/** Local committed-prefix journal, independent of Activity/AudioRecord.
 * Single writer, private per-session directory, no audio rewrite or tail promotion.
 * Requires java.nio.file support (Android API 26+ before use).
 * The sample ledger is not a hardware PTS or power-loss attestation.
 */
internal class LabMultiPartProof(private val folder: File, private val session: UUID) {
    data class Receipt(val index: Int, val start: Long, val end: Long, val bytes: Long, val sha: String)
    data class Recovery(val receipts: List<Receipt>, val finished: Boolean)
    private val maxParts = 128
    private fun requireSafe(ok: Boolean) = check(ok) { "LAB_MULTI_PART_PROOF_HOLD" }
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

    /** Synced temporary metadata, then exclusive atomic publication by hard link.
     * Never replace a destination even if another writer races; no weaker fallback.
     * The private temp receipt is deliberately retained on publication failure.
     */
    private fun publish(dest: File, text: String) {
        requireSafe(!present(dest))
        val tmp = file("${dest.name}.${UUID.randomUUID()}.tmp")
        requireSafe(tmp.createNewFile())
        FileOutputStream(tmp).use { it.write(text.toByteArray(Charsets.US_ASCII)); it.fd.sync() }
        Files.createLink(dest.toPath(), tmp.toPath())
        Files.delete(tmp.toPath())
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
        val receipt = inspect(index, prior.lastOrNull()?.end ?: 0L)
        val dest = file(stem(index) + ".commit")
        publish(dest, encode(receipt))
        requireSafe(recover().lastOrNull() == receipt)
        return receipt
    }
}
