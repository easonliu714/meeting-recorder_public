package com.example.meeting_recorder.public_lab_v34.groq_stt_lab

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.UUID

private fun wav(dir: File, n: Int, frames: Int, marker: Byte): File {
    val size = frames * 2
    val b = ByteBuffer.allocate(44 + size).order(ByteOrder.LITTLE_ENDIAN)
    fun tag(s: String) { b.put(s.toByteArray(Charsets.US_ASCII)) }
    tag("RIFF"); b.putInt(36 + size); tag("WAVE"); tag("fmt "); b.putInt(16)
    b.putShort(1); b.putShort(1); b.putInt(16000); b.putInt(32000); b.putShort(2); b.putShort(16)
    tag("data"); b.putInt(size); repeat(size) { b.put(marker) }
    return File(dir, "part_%06d.wav".format(n)).apply { writeBytes(b.array()) }
}
private fun reject(block: () -> Unit) { check(runCatching(block).isFailure) }
fun main() {
    val base = Files.createTempDirectory("lab-multipart-host-").toFile()
    var count = 0
    fun case(name: String, body: (File, UUID, LabMultiPartProof) -> Unit) {
        val id = UUID.randomUUID(); val folder = File(base, id.toString()); check(folder.mkdir())
        body(folder, id, LabMultiPartProof(folder,id)); count++; println("PASS $name")
    }
    try {
        case("no committed receipt fails closed") { d,_,j ->
            reject{j.recover()}; wav(d,1,48000,1); reject{j.recover()}; check(j.commit(1).end==48000L)
        }
        case("three physical parts / cumulative frames / restart") { d,id,j ->
            (1..3).forEach { wav(d,it,48000,it.toByte()); j.commit(it) }
            val r=LabMultiPartProof(d,id).recover(); check(r.map{it.start}==listOf(0L,48000L,96000L)); check(r.last().end==144000L); check(r.map{it.sha}.toSet().size==3)
        }
        case("uncommitted WAV and raw tail not promoted") { d,id,j ->
            wav(d,1,48000,1); j.commit(1); wav(d,2,48000,2); val tail=File(d,"part_000003_inflight.pcm").apply{writeBytes(byteArrayOf(1,2,3))}; check(LabMultiPartProof(d,id).recover().size==1); check(tail.length()==3L)
        }
        case("no overwrite / out-of-order commit") { d,_,j ->
            val f=wav(d,1,48000,1); val raw=f.readBytes(); j.commit(1); val c=File(d,"part_000001.commit"); val receipt=c.readBytes(); reject{j.commit(1)}; reject{j.commit(3)}; check(f.readBytes().contentEquals(raw) && c.readBytes().contentEquals(receipt))
        }
        case("same-size WAV mutation rejected") { d,_,j ->
            val f=wav(d,1,48000,1); j.commit(1); val raw=f.readBytes(); raw[50]=5; f.writeBytes(raw); reject{j.recover()}; check(f.readBytes().contentEquals(raw))
        }
        case("missing committed source rejected") { d,_,j ->
            val f=wav(d,1,48000,1); j.commit(1); check(f.renameTo(File(d,"fixture-moved.wav"))); reject{j.recover()}
        }
        case("missing prefix receipt rejected") { d,_,j ->
            wav(d,1,48000,1);j.commit(1);wav(d,2,48000,2);j.commit(2);check(File(d,"part_000001.commit").renameTo(File(d,"fixture-moved.txt")));reject{j.recover()}
        }
        case("forged receipt rejected") { d,_,j ->
            wav(d,1,48000,1);j.commit(1);val f=File(d,"part_000001.commit");f.writeText(f.readText().replace("\t48000\t","\t48001\t"));reject{j.recover()}
        }
        case("unsealed RIFF rejected") { d,_,j ->
            val f=wav(d,1,48000,1);val raw=f.readBytes();raw[4]=0;f.writeBytes(raw);reject{j.commit(1)};check(!File(d,"part_000001.commit").exists())
        }
        case("symlink source rejected") { d,_,j ->
            val f=wav(d,1,48000,1);val other=File(d,"fixture.wav");check(f.renameTo(other));Files.createSymbolicLink(f.toPath(),other.toPath());reject{j.commit(1)}
        }
        case("normal terminal is immutable and binds final extent") { d,id,j ->
            (1..3).forEach { wav(d,it,48000,it.toByte()); j.commit(it) }
            check(!j.recoverSnapshot().finished)
            reject { j.finish(2) }; check(!File(d,"finished_v1.txt").exists())
            check(j.finish(3).finished)
            val r=LabMultiPartProof(d,id).recoverSnapshot(); check(r.finished && r.receipts.size==3)
            reject{j.finish(3)}; wav(d,4,48000,4); reject{j.commit(4)}
            check(File(d,"part_000004.wav").exists())
        }
        case("missing final committed receipt after terminal rejected") { d,id,j ->
            (1..3).forEach { wav(d,it,48000,it.toByte()); j.commit(it) };j.finish(3)
            check(File(d,"part_000003.commit").renameTo(File(d,"fixture-missing.txt")))
            reject { LabMultiPartProof(d,id).recoverSnapshot() }
            check(File(d,"part_000003.wav").exists())
        }
        case("malformed terminal cannot become complete") { d,_,j ->
            wav(d,1,48000,1);j.commit(1);j.finish(1)
            File(d,"finished_v1.txt").writeText("forged")
            reject{j.recoverSnapshot()};reject{j.commit(2)}
        }
        case("stream writer seals four chunks across read boundaries") { d,id,_ ->
            val counts=mutableListOf<Int>()
            LabMultiPartSink(d,id,12,4,{true},{counts.add(it)}).use { s ->
                s.accept(ByteArray(10){1});s.accept(ByteArray(18){2});s.accept(ByteArray(20){3});s.finish(true)
            }
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(r.finished && r.receipts.size==4 && r.receipts.last().end==24L)
            check(counts==listOf(1,2,3,4))
        }
        case("later interruption keeps raw tail") { d,id,_ ->
            LabMultiPartSink(d,id,12,4,{true}).use { s ->s.accept(ByteArray(32){7});s.finish(false)}
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(!r.finished && r.receipts.size==2 && r.receipts.last().end==12L)
            check(File(d,"part_000003_inflight.pcm").length()==8L)
            check(!File(d,"part_000003.wav").exists())
        }
        case("normal finish seals short last part") { d,id,_ ->
            LabMultiPartSink(d,id,12,4,{true}).use { s ->s.accept(ByteArray(16){4});s.finish(true)}
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(r.finished && r.receipts.map {it.bytes}==listOf(56L,48L))
        }
        case("early interruption never promotes first raw tail") { d,id,_ ->
            LabMultiPartSink(d,id,12,4,{true}).use { s ->s.accept(ByteArray(4){3});s.finish(false)}
            check(File(d,"part_000001_inflight.pcm").length()==4L)
            reject {LabMultiPartProof(d,id).recover()}
        }
        case("controlled storage failure preserves prior receipt") { d,id,_ ->
            var space=true
            LabMultiPartSink(d,id,12,4,{space}).use { s ->
                s.accept(ByteArray(12){2});s.accept(ByteArray(4){3})
                space=false;reject{s.accept(ByteArray(8){1})}
            }
            val r=LabMultiPartProof(d,id).recoverSnapshot()
            check(!r.finished && r.receipts.size==1)
            check(File(d,"part_000002_inflight.pcm").length()==4L)
        }
        case("hardlink IO refused keeps immutable WAV and no receipt") { d,id,_ ->
            val f=wav(d,1,48000,1)
            val j=LabMultiPartProof(d,id,{_,_->throw java.io.IOException("sensitive sandbox path")})
            val e=runCatching{j.commit(1)}.exceptionOrNull()
            check(e?.message=="LAB_MULTI_HARDLINK_IO_HOLD")
            check(f.exists() && !File(d,"part_000001.commit").exists())
            reject{LabMultiPartProof(d,id).recover()}
            check(d.listFiles()!!.any{it.name.endsWith(".tmp")})
        }
        case("hardlink unsupported keeps original data and no commit") { d,id,_ ->
            val f=wav(d,1,48000,1)
            val j=LabMultiPartProof(d,id,{_,_->throw UnsupportedOperationException("unsupported")})
            val e=runCatching{j.commit(1)}.exceptionOrNull()
            check(e?.message=="LAB_MULTI_HARDLINK_UNSUPPORTED_HOLD")
            check(f.exists() && !File(d,"part_000001.commit").exists())
        }
        println("HOST_REGRESSION=$count/$count PASS")
    } finally { base.deleteRecursively() }
}
